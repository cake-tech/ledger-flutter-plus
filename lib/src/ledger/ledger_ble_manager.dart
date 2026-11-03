import "dart:async";

import "package:flutter/foundation.dart";
import "package:universal_ble/universal_ble.dart";

import "../api/connection_manager.dart";
import "../exceptions/ledger_exception.dart";
import "../ledger_interface.dart";
import "../models/connection_change_event.dart";
import "../models/discovered_ledger.dart";
import "../models/ledger_device.dart";
import "../operations/ledger_operations.dart";
import "connection_type.dart";
import "ledger_gatt_gateway.dart";
import "ledger_transformer.dart";

const _bleMasterTimeout = Duration(seconds: 60);
const _bleConnectionTimeout = Duration(seconds: 30);
const _bleCheckConnectionTimeout = Duration(seconds: 5);

class LedgerBleConnectionManager extends ConnectionManager {
  bool _disposed = false;
  bool _superseded = false;

  final PermissionRequestCallback onPermissionRequest;

  final _connectedDevices = <String, ({LedgerGattGateway gateway, LedgerDevice device})>{};
  final _attempts = <String, _ConnectionAttempt>{};
  final _epochs = <String, int>{};
  static final _drains = <String, Future<void>>{};
  static final _retiredDevices = <String>{};
  static LedgerBleConnectionManager? _callbackOwner;
  static LedgerBleConnectionManager? _availabilityCallbackOwner;

  final List<OnConnectionChange> _connectionChangeListeners = [];

  final _onConnectionChangeController = StreamController<BleConnectionChangeEvent>.broadcast();
  final _sessionStateController = StreamController<BleConnectionChangeEvent>.broadcast(sync: true);
  final _statusStateChangesController = StreamController<AvailabilityState>();

  LedgerBleConnectionManager({
    required this.onPermissionRequest,
  }) {
    _callbackOwner?._supersede();
    _callbackOwner = this;
    _connectionChangeListeners.add(_handleConnectionChange);
    UniversalBle.onConnectionChange = (deviceId, isConnected, err) {
      if (!identical(_callbackOwner, this)) return;
      final state = isConnected ? BleConnectionState.connected : BleConnectionState.disconnected;

      // Copy the list because we get a ConcurrentModificationError otherwise
      final List<OnConnectionChange> connectionChangeListeners = [
        ..._connectionChangeListeners,
      ];

      for (final OnConnectionChange listener in connectionChangeListeners) {
        try {
          listener(deviceId, isConnected, err);
        } catch (e) {
          debugPrint("Error in connection change listener: $e");
        }
      }
      _emitState(deviceId, state);
    };
  }

  @override
  Future<void> connect(LedgerDevice device) async {
    await connectSession(device);
  }

  /// Establishes a connection and returns its session generation.
  Future<int> connectSession(LedgerDevice device) async {
    if (_disposed || _superseded) throw LedgerManagerDisposedException(ConnectionType.ble);

    final previous = _attempts[device.id];
    if (previous != null) _retireAttempt(previous);
    if (_connectedDevices.containsKey(device.id)) {
      unawaited(_disconnect(device.id).catchError((Object _) {}));
    }

    final attempt = _ConnectionAttempt(device.id);
    _attempts[device.id] = attempt;
    return Future.any([
      _connectAttempt(device, attempt),
      attempt.cancelled.future.then<int>((_) => throw ConnectionLostException(connectionType: ConnectionType.ble)),
    ]);
  }

  Future<void> _waitForDrain(String deviceId) async {
    Future<void> waitForAll() async {
      while (_drains.containsKey(deviceId)) {
        await _drains[deviceId];
      }
    }

    try {
      await waitForAll().timeout(_bleCheckConnectionTimeout);
    } on TimeoutException catch (error) {
      throw EstablishConnectionException(connectionType: ConnectionType.ble, nestedError: error);
    }
  }

  Future<int> _connectAttempt(LedgerDevice device, _ConnectionAttempt attempt) async {
    void checkSession() {
      if (_disposed || _superseded || !attempt.valid || !identical(_attempts[device.id], attempt)) {
        throw ConnectionLostException(connectionType: ConnectionType.ble);
      }
    }

    try {
      await _waitForDrain(device.id);
      checkSession();
      final epoch = (_epochs[device.id] ?? 0) + 1;
      _epochs[device.id] = epoch;

      final availabilityState = await UniversalBle.getBluetoothAvailabilityState();
      checkSession();
      final granted = await onPermissionRequest(availabilityState);
      checkSession();
      if (!granted) return epoch;

      UniversalBle.timeout = _bleMasterTimeout;
      final requireDisconnected = _retiredDevices.contains(device.id);
      attempt.nativeStarted = true;
      try {
        final stateFuture = UniversalBle.getConnectionState(device.id);
        attempt.track(stateFuture);
        final connectionState = await stateFuture.timeout(
          _bleCheckConnectionTimeout,
          onTimeout: () {
            if (requireDisconnected) {
              throw TimeoutException("UniversalBle.getConnectionState", _bleCheckConnectionTimeout);
            }
            return BleConnectionState.disconnected;
          },
        );
        checkSession();
        if (requireDisconnected && connectionState != BleConnectionState.disconnected) {
          throw ConnectionLostException(connectionType: ConnectionType.ble);
        }
        switch (connectionState) {
          case BleConnectionState.connected:
          case BleConnectionState.connecting:
            break;
          case BleConnectionState.disconnected:
          case BleConnectionState.disconnecting:
            final connecting = UniversalBle.connect(device.id);
            attempt.track(connecting);
            await connecting;
            checkSession();
        }
      } on LedgerException {
        rethrow;
      } catch (e) {
        checkSession();
        throw EstablishConnectionException(
          connectionType: ConnectionType.ble,
          nestedError: e,
        );
      }

      final discovering = UniversalBle.discoverServices(device.id);
      attempt.track(discovering);
      final services = await discovering.timeout(
        _bleConnectionTimeout,
        onTimeout: () => throw TimeoutException(
          "UniversalBle.discoverServices",
          _bleConnectionTimeout,
        ),
      );

      checkSession();

      final ledger = DiscoveredLedger(
        device: device,
        services: services,
        subscription: null,
      );

      late final LedgerGattGateway gateway;
      gateway = LedgerGattGateway(
        ledger: ledger,
        disconnectOnStartFailure: false,
        onWriteTimeout: () {
          if (identical(_connectedDevices[device.id]?.gateway, gateway)) {
            unawaited(_disconnect(device.id).catchError((Object _) {}));
          } else {
            gateway.connectionLost();
          }
        },
      );
      attempt.gateway = gateway;

      final starting = gateway.start();
      attempt.track(starting);
      await starting.timeout(
        _bleMasterTimeout,
        onTimeout: () => throw TimeoutException(
          "gateway.start",
          _bleMasterTimeout,
        ),
      );
      checkSession();
      _connectedDevices[device.id] = (gateway: gateway, device: device);
      _retiredDevices.remove(device.id);
      _attempts.remove(device.id);
      return epoch;
    } catch (_) {
      if (attempt.valid) _retireAttempt(attempt, notify: false);
      rethrow;
    } finally {
      if (identical(_attempts[device.id], attempt)) _attempts.remove(device.id);
      attempt.done.complete();
    }
  }

  void _handleConnectionChange(String deviceId, bool isConnected, String? err) {
    if (!isConnected) {
      _epochs[deviceId] = (_epochs[deviceId] ?? 0) + 1;
      final attempt = _attempts[deviceId];
      if (attempt != null && attempt.nativeStarted) _retireAttempt(attempt);
      final gateway = _connectedDevices.remove(deviceId)?.gateway;
      if (gateway != null) _retireGateway(deviceId, gateway);
    }
  }

  void _emitState(String deviceId, BleConnectionState state, {bool notifyPublic = true}) {
    final event = BleConnectionChangeEvent(deviceId: deviceId, newState: state);
    if (!_sessionStateController.isClosed) _sessionStateController.add(event);
    if (notifyPublic && !_onConnectionChangeController.isClosed) _onConnectionChangeController.add(event);
  }

  void _trackDrain(String deviceId, Future<void> drain) {
    final previous = _drains[deviceId];
    final combined = Future.wait<void>([
      if (previous != null) previous,
      drain.then<void>((_) {}, onError: (Object _, StackTrace __) {}),
    ]).then<void>((_) {});
    _drains[deviceId] = combined;
    unawaited(combined.then((_) {
      if (identical(_drains[deviceId], combined)) unawaited(_drains.remove(deviceId));
    }));
  }

  void _retireGateway(String deviceId, LedgerGattGateway gateway) {
    gateway.connectionLost();
    _retiredDevices.add(deviceId);
    _trackDrain(deviceId, gateway.writesSettled);
  }

  void _retireAttempt(_ConnectionAttempt attempt, {bool notify = true}) {
    if (!attempt.valid) return;
    attempt.valid = false;
    if (notify) attempt.cancelled.complete();
    if (identical(_attempts[attempt.deviceId], attempt)) _attempts.remove(attempt.deviceId);

    final gateway = attempt.gateway;
    if (gateway != null) {
      if (identical(_connectedDevices[attempt.deviceId]?.gateway, gateway)) {
        _connectedDevices.remove(attempt.deviceId);
      }
      _retireGateway(attempt.deviceId, gateway);
    }
    if (attempt.nativeStarted) {
      _retiredDevices.add(attempt.deviceId);
      final cleanup = () async {
        await attempt.done.future;
        await Future.wait(attempt.work);
        await UniversalBle.disconnect(attempt.deviceId);
      }();
      _trackDrain(attempt.deviceId, cleanup);
    }
  }

  Set<String> _retireAll() {
    final deviceIds = {..._attempts.keys, ..._connectedDevices.keys};
    _attempts.values.toList().forEach(_retireAttempt);
    for (final deviceId in _connectedDevices.keys.toList()) {
      unawaited(_disconnect(deviceId).catchError((Object _) {}));
    }
    return deviceIds;
  }

  void _supersede() {
    if (_disposed || _superseded) return;
    _superseded = true;
    _clearAvailabilityCallback();
    _retireAll();
  }

  void _clearAvailabilityCallback() {
    if (!identical(_availabilityCallbackOwner, this)) return;
    UniversalBle.onAvailabilityChange = null;
    _availabilityCallbackOwner = null;
  }

  @override
  Future<T> sendRawOperation<T>(
    LedgerDevice device,
    LedgerRawOperation<T> operation,
    LedgerTransformer? transformer,
  ) async {
    if (_disposed || _superseded) throw LedgerManagerDisposedException(ConnectionType.ble);

    final d = _connectedDevices[device.id];
    if (d == null) {
      throw DeviceNotConnectedException(
        requestedOperation: "ble_manager: sendOperation",
        connectionType: ConnectionType.ble,
      );
    }

    return d.gateway.sendOperation<T>(
      operation,
      transformer: transformer,
    );
  }

  @override
  Future<AvailabilityState> get status {
    if (_disposed || _superseded) throw LedgerManagerDisposedException(ConnectionType.ble);

    return UniversalBle.getBluetoothAvailabilityState();
  }

  @override
  Stream<AvailabilityState> get statusStateChanges {
    if (_disposed || _superseded) throw LedgerManagerDisposedException(ConnectionType.ble);

    _availabilityCallbackOwner = this;
    UniversalBle.onAvailabilityChange = (state) {
      if (_disposed || _superseded || !identical(_availabilityCallbackOwner, this)) return;
      _statusStateChangesController.add(state);
    };
    return _statusStateChangesController.stream;
  }

  @override
  Future<List<LedgerDevice>> get devices async {
    if (_disposed || _superseded) throw LedgerManagerDisposedException(ConnectionType.ble);

    return _connectedDevices.values.map((e) => e.device).toList();
  }

  @override
  Stream<BleConnectionState> deviceStateChanges(String deviceId) {
    if (_disposed || _superseded) throw LedgerManagerDisposedException(ConnectionType.ble);

    return _onConnectionChangeController.stream.where((e) => e.deviceId == deviceId).map((e) => e.newState);
  }

  Stream<BleConnectionState> sessionStateChanges(String deviceId) {
    if (_disposed || _superseded) throw LedgerManagerDisposedException(ConnectionType.ble);
    return _sessionStateController.stream.where((e) => e.deviceId == deviceId).map((e) => e.newState);
  }

  bool hasDeviceSession(String deviceId, [int? epoch]) =>
      !_disposed &&
      !_superseded &&
      _connectedDevices.containsKey(deviceId) &&
      (epoch == null || _epochs[deviceId] == epoch);

  @override
  Future<void> disconnect(String deviceId) async {
    if (_disposed || _superseded) throw LedgerManagerDisposedException(ConnectionType.ble);

    try {
      await _disconnect(deviceId);
    } on EstablishConnectionException catch (error) {
      throw DisposeException(connectionType: ConnectionType.ble, cause: error.nestedError);
    }
  }

  // Bypass dispose check here because this method is called from dispose
  Future<void> _disconnect(String deviceId) async {
    _epochs[deviceId] = (_epochs[deviceId] ?? 0) + 1;
    final attempt = _attempts[deviceId];
    if (attempt != null) {
      _retireAttempt(attempt);
      _emitState(deviceId, BleConnectionState.disconnected, notifyPublic: false);
      await _waitForDrain(deviceId);
      return;
    }
    final gateway = _connectedDevices.remove(deviceId)?.gateway;
    if (gateway != null) _retireGateway(deviceId, gateway);
    _emitState(deviceId, BleConnectionState.disconnected, notifyPublic: false);
    final disconnecting = gateway != null ? gateway.disconnect() : UniversalBle.disconnect(deviceId);
    _trackDrain(deviceId, disconnecting);
    await _waitForDrain(deviceId);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    _clearAvailabilityCallback();
    unawaited(_statusStateChangesController.close());
    final deviceIds = _retireAll();
    final disconnections = deviceIds.map((deviceId) async {
      try {
        await _waitForDrain(deviceId);
      } catch (e) {
        // The unresolved drain remains in place for subsequent connections.
      }
    }).toList();
    await Future.wait(disconnections);
    _connectedDevices.clear();
    if (identical(_callbackOwner, this)) {
      UniversalBle.onConnectionChange = null;
      _callbackOwner = null;
    }
    unawaited(_onConnectionChangeController.close());
    unawaited(_sessionStateController.close());
  }

  @override
  final ConnectionType connectionType = ConnectionType.ble;
}

class _ConnectionAttempt {
  final String deviceId;
  final cancelled = Completer<void>();
  final done = Completer<void>();
  final work = <Future<void>>[];
  bool valid = true;
  bool nativeStarted = false;
  LedgerGattGateway? gateway;

  _ConnectionAttempt(this.deviceId);

  void track<T>(Future<T> future) {
    work.add(future.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  }
}
