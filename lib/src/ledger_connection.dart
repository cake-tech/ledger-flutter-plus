import "dart:async";

import "package:universal_ble/universal_ble.dart" show BleConnectionState;

import "api/connection_manager.dart";
import "concurrency/request_queue.dart";
import "exceptions/ledger_exception.dart";
import "ledger/connection_type.dart";
import "ledger/ledger_ble_manager.dart";
import "ledger/ledger_transformer.dart";
import "models/ledger_device.dart";
import "operations/ledger_operations.dart";

class LedgerConnection {
  final RequestQueue _requestQueue = RequestQueue();
  final ConnectionManager _connectionManager;

  final LedgerDevice device;

  bool _isDisconnected = false;
  StreamSubscription<BleConnectionState>? _connectionSubscription;
  final Set<RequestQueue> _nestedQueues = {};
  bool get isDisconnected => _isDisconnected;

  ConnectionType get connectionType => _connectionManager.connectionType;

  LedgerConnection(
    this._connectionManager,
    this.device, {
    int? bleSession,
  }) {
    if (connectionType == ConnectionType.ble) {
      final manager = _connectionManager;
      final states = manager is LedgerBleConnectionManager
          ? manager.sessionStateChanges(device.id)
          : manager.deviceStateChanges(device.id);
      _connectionSubscription = states.listen((state) {
        if (state == BleConnectionState.disconnected) _terminateBleSession();
      });
      if (manager is LedgerBleConnectionManager && !manager.hasDeviceSession(device.id, bleSession)) {
        _terminateBleSession();
      }
    }
  }

  void _terminateBleSession() {
    if (_isDisconnected) return;
    _isDisconnected = true;
    final error = ConnectionLostException(connectionType: ConnectionType.ble);
    _requestQueue.dispose(error: error);
    for (final queue in _nestedQueues) {
      queue.dispose(error: error);
    }
    _nestedQueues.clear();
    unawaited(_connectionSubscription?.cancel());
    _connectionSubscription = null;
  }

  /// Cancels pending and ongoing requests and disconnects the device.
  Future<void> disconnect() {
    if (_isDisconnected) {
      return Future.value();
    }
    if (connectionType == ConnectionType.ble) {
      _terminateBleSession();
    } else {
      _isDisconnected = true;
      _requestQueue.dispose();
    }
    return _connectionManager.disconnect(device.id);
  }

  Future<T> sendOperation<T>(
    LedgerOperation<T> operation, {
    LedgerTransformer? transformer,
  }) async {
    if (_isDisconnected) {
      throw DeviceNotConnectedException(
        requestedOperation: "(_isDisconnected = $_isDisconnected) sendOperation",
        connectionType: _connectionManager.connectionType,
      );
    }

    return _requestQueue.enqueueRequest(
      () => _sendOperationImpl(device, operation, transformer),
    );
  }

  /// Sends a Ledger operation to the device.
  /// Careful when calling this method because it doesn't queue the operation.
  Future<T> _sendOperationImpl<T>(
    LedgerDevice device,
    LedgerOperation<T> operation,
    LedgerTransformer? transformer,
  ) async {
    switch (operation) {
      case LedgerRawOperation<T>():
        return _connectionManager.sendRawOperation<T>(
          device,
          operation,
          transformer,
        );
      case LedgerComplexOperation<T>():
        // We need to use a nested request queue to ensure that each inner operation
        //   has all send calls executed in the same order as they were called
        //   even if the operation is unawaited.
        final RequestQueue nestedRequestQueue = RequestQueue();
        _nestedQueues.add(nestedRequestQueue);
        var outstanding = 0;
        var finished = false;
        void releaseIfFinished() {
          if (finished && outstanding == 0) _nestedQueues.remove(nestedRequestQueue);
        }

        Future<Y> send<Y>(LedgerOperation<Y> simpleOp) {
          if (_isDisconnected) {
            return Future.error(ConnectionLostException(connectionType: connectionType));
          }
          outstanding++;
          final future = nestedRequestQueue.enqueueRequest(
            () => _sendOperationImpl(device, simpleOp, transformer),
          );
          unawaited(future.then<void>((_) {
            outstanding--;
            releaseIfFinished();
          }, onError: (Object _, StackTrace __) {
            outstanding--;
            releaseIfFinished();
          }));
          return future;
        }

        try {
          return await operation.invoke(send);
        } finally {
          finished = true;
          releaseIfFinished();
        }
    }
  }
}
