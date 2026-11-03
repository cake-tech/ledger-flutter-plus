import "dart:async";
import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:ledger_flutter_plus/ledger_flutter_plus.dart";
import "package:ledger_flutter_plus/ledger_flutter_plus_dart.dart";
import "package:ledger_flutter_plus/src/concurrency/request_queue.dart";
import "package:ledger_usb_plus/ledger_usb_platform_interface.dart";
import "package:ledger_usb_plus/usb_device.dart";

const _device = LedgerDevice(
  id: "test-device",
  name: "test",
  connectionType: ConnectionType.ble,
  deviceInfo: LedgerDeviceType.nanoX,
);

final _lost = isA<ConnectionLostException>().having((e) => e.connectionType, "connectionType", ConnectionType.ble);

class _BlePlatform extends UniversalBlePlatform {
  bool connected = false;
  int connectCalls = 0;
  Completer<void>? writeGate;
  Error? writeError;
  bool timeoutWrite = false;
  bool failDisconnect = false;
  bool failConnectionState = false;
  Completer<void>? stateGate;
  Completer<void>? stateEntered;
  Completer<void>? discoveryGate;
  Completer<void>? discoveryEntered;
  Completer<void>? mtuGate;
  Completer<void>? mtuEntered;
  Completer<void>? disconnectGate;
  Completer<void>? disconnectEntered;
  int disconnectCalls = 0;
  int notificationSubscriptions = 0;
  final writes = <Uint8List>[];
  final _writeEvents = StreamController<int>.broadcast(sync: true);

  Future<void> waitForWrites(int count) async {
    if (writes.length < count) await _writeEvents.stream.firstWhere((n) => n >= count);
  }

  void loseConnection() {
    connected = false;
    updateConnection(_device.id, false);
  }

  void response(List<int> packet) {
    updateCharacteristicValue(
      _device.id,
      _device.deviceInfo.notifyCharacteristicKey,
      Uint8List.fromList(packet),
      null,
    );
  }

  @override
  Future<AvailabilityState> getBluetoothAvailabilityState() async => AvailabilityState.poweredOn;

  @override
  Future<BleConnectionState> getConnectionState(String deviceId) async {
    if (stateGate != null && stateEntered != null && !stateEntered!.isCompleted) stateEntered!.complete();
    await stateGate?.future;
    if (failConnectionState) throw StateError("state unavailable");
    return connected ? BleConnectionState.connected : BleConnectionState.disconnected;
  }

  @override
  Future<void> connect(
    String deviceId, {
    Duration? connectionTimeout,
    bool autoConnect = false,
    dynamic platformConfig,
  }) async {
    connectCalls++;
    connected = true;
    updateConnection(deviceId, true);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    disconnectCalls++;
    if (disconnectEntered != null && !disconnectEntered!.isCompleted) disconnectEntered!.complete();
    await disconnectGate?.future;
    if (failDisconnect) throw StateError("disconnect failed");
    connected = false;
    updateConnection(deviceId, false);
  }

  @override
  Future<List<BleService>> discoverServices(String deviceId, bool withDescriptors) async {
    if (discoveryEntered != null && !discoveryEntered!.isCompleted) discoveryEntered!.complete();
    await discoveryGate?.future;
    return [
      BleService(_device.deviceInfo.serviceId, [
        BleCharacteristic(_device.deviceInfo.writeCharacteristicKey, [CharacteristicProperty.write], []),
        BleCharacteristic(_device.deviceInfo.notifyCharacteristicKey, [CharacteristicProperty.notify], []),
      ]),
    ];
  }

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) async {
    if (mtuEntered != null && !mtuEntered!.isCompleted) mtuEntered!.complete();
    await mtuGate?.future;
    return expectedMtu;
  }

  @override
  Future<void> setNotifiable(
    String deviceId,
    String service,
    String characteristic,
    BleInputProperty bleInputProperty,
  ) async {
    notificationSubscriptions++;
  }

  @override
  Future<void> writeValue(
    String deviceId,
    String service,
    String characteristic,
    Uint8List value,
    BleOutputProperty bleOutputProperty,
  ) async {
    writes.add(value);
    _writeEvents.add(writes.length);
    await writeGate?.future;
    if (timeoutWrite) throw TimeoutException("write timed out");
    if (writeError != null) throw writeError!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ByteOperation extends LedgerRawOperation<int> {
  final int command;
  _ByteOperation(this.command);

  @override
  Future<List<Uint8List>> write(ByteDataWriter writer) async => [
        Uint8List.fromList([command])
      ];

  @override
  Future<int> read(ByteDataReader reader) async => reader.readUint8();
}

class _TwoOperations extends LedgerComplexOperation<List<int>> {
  const _TwoOperations();

  @override
  Future<List<int>> invoke(LedgerSendFct send) async {
    final first = await send(_ByteOperation(1));
    final second = await send(_ByteOperation(2));
    return [first, second];
  }
}

class _ParallelOperations extends LedgerComplexOperation<List<int>> {
  const _ParallelOperations();

  @override
  Future<List<int>> invoke(LedgerSendFct send) => Future.wait([send(_ByteOperation(1)), send(_ByteOperation(2))]);
}

class _RejectedOperation extends _ByteOperation {
  _RejectedOperation() : super(1);

  @override
  Future<int> read(ByteDataReader reader) async => throw LedgerDeviceException(
        connectionType: ConnectionType.ble,
        errorCode: 0x6985,
      );
}

class _SlowWriteOperation extends _ByteOperation {
  final entered = Completer<void>();
  final release = Completer<void>();
  _SlowWriteOperation() : super(1);

  @override
  Future<List<Uint8List>> write(ByteDataWriter writer) async {
    entered.complete();
    await release.future;
    return super.write(writer);
  }
}

class _ReadProbe extends _ByteOperation {
  int reads = 0;
  _ReadProbe() : super(1);

  @override
  Future<int> read(ByteDataReader reader) {
    reads++;
    return super.read(reader);
  }
}

class _BlockingTransformer extends LedgerTransformer {
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<Uint8List> onTransform(List<Uint8List> transform) async {
    entered.complete();
    await release.future;
    return transform.single;
  }
}

class _UsbPlatform extends LedgerUsbPlatform {
  Uint8List? lastWrite;

  @override
  Future<int> transferOut(Uint8List data, int timeout) async {
    lastWrite = data;
    return data.length;
  }

  @override
  Future<Uint8List?> transferIn(int packetSize, int timeout) async =>
      Uint8List.fromList([lastWrite![0], lastWrite![1], 5, 0, 0, 0, 1, 42]);

  @override
  Future<bool> close() async => true;
  @override
  Future<List<UsbDevice>> getDevices() async => [];
  @override
  Future<bool> open(UsbDevice usbDevice) async => true;
  @override
  Future<bool> requestPermission(UsbDevice usbDevice) async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group("BLE session lifecycle", () {
    late _BlePlatform platform;
    late LedgerBleConnectionManager manager;

    Future<LedgerConnection> connect() async {
      await manager.connect(_device);
      return LedgerConnection(manager, _device);
    }

    setUp(() {
      platform = _BlePlatform();
      UniversalBle.setInstance(platform);
      manager = LedgerBleConnectionManager(onPermissionRequest: (_) async => true);
    });

    tearDown(() async {
      await manager.dispose();
      await platform._writeEvents.close();
    });

    test("gateway startup does not expose a usable session or accept APDUs", () async {
      platform.mtuGate = Completer<void>();
      platform.mtuEntered = Completer<void>();
      final starting = manager.connectSession(_device);
      await platform.mtuEntered!.future;
      try {
        expect(await manager.devices, isEmpty);
        expect(manager.hasDeviceSession(_device.id), isFalse);
        final premature = LedgerConnection(manager, _device);
        expect(premature.isDisconnected, isTrue);
        await expectLater(
          premature.sendOperation(_ByteOperation(1)),
          throwsA(isA<DeviceNotConnectedException>()),
        );
        await expectLater(
          manager.sendRawOperation(_device, _ByteOperation(1), null),
          throwsA(isA<DeviceNotConnectedException>()),
        );
        expect(platform.writes, isEmpty);
      } finally {
        platform.mtuGate!.complete();
        platform.mtuGate = null;
        await starting;
      }

      final session = await starting;
      expect(await manager.devices, [_device]);
      expect(manager.hasDeviceSession(_device.id, session), isTrue);
      final connection = LedgerConnection(manager, _device, bleSession: session);
      final next = connection.sendOperation(_ByteOperation(2));
      await platform.waitForWrites(1);
      platform.response([5, 0, 0, 0, 1, 7]);
      expect(await next, 7);
    });

    test("disconnect during gateway startup retires it before reconnect", () async {
      platform.mtuGate = Completer<void>();
      platform.mtuEntered = Completer<void>();
      final starting = manager.connect(_device);
      final failure = expectLater(starting, throwsA(_lost));
      await platform.mtuEntered!.future;
      final disconnecting = manager.disconnect(_device.id);
      await failure;
      final reconnecting = manager.connect(_device);
      try {
        await Future<void>.delayed(Duration.zero);
        expect(platform.connectCalls, 1);
        expect(platform.notificationSubscriptions, 0);
      } finally {
        platform.mtuGate!.complete();
        platform.mtuGate = null;
        await Future.wait([disconnecting, reconnecting]);
      }

      expect(platform.connectCalls, 2);
      expect(platform.notificationSubscriptions, 1);
      final connection = LedgerConnection(manager, _device);
      final next = connection.sendOperation(_ByteOperation(2));
      await platform.waitForWrites(1);
      platform.response([5, 0, 0, 0, 1, 8]);
      expect(await next, 8);
    });

    test("replacement detaches old availability callbacks and preserves its own", () async {
      final old = manager;
      final oldEvents = <AvailabilityState>[];
      final oldSubscription = old.statusStateChanges.listen(oldEvents.add);
      try {
        await Future<void>.delayed(Duration.zero);
        expect(oldEvents, [AvailabilityState.poweredOn]);
        final oldCallback = platform.onAvailabilityChange!;
        manager = LedgerBleConnectionManager(onPermissionRequest: (_) async => true);
        await old.dispose();
        expect(platform.onAvailabilityChange, isNull);
        expect(() => oldCallback(AvailabilityState.poweredOff), returnsNormally);
        expect(oldEvents, [AvailabilityState.poweredOn]);

        final newEvents = <AvailabilityState>[];
        final newSubscription = manager.statusStateChanges.listen(newEvents.add);
        try {
          await Future<void>.delayed(Duration.zero);
          final newCallback = platform.onAvailabilityChange!;
          await old.dispose();
          expect(identical(platform.onAvailabilityChange, newCallback), isTrue);
          newCallback(AvailabilityState.poweredOff);
          await Future<void>.delayed(Duration.zero);
          expect(newEvents, [AvailabilityState.poweredOn, AvailabilityState.poweredOff]);
          expect(oldEvents, [AvailabilityState.poweredOn]);
        } finally {
          await newSubscription.cancel();
        }
      } finally {
        await oldSubscription.cancel();
        await old.dispose();
      }
    });

    test("physical loss fails active and queued requests and a reconnect starts fresh", () async {
      final old = await connect();
      final active = old.sendOperation(const _TwoOperations());
      final queued = old.sendOperation(_ByteOperation(3));
      final activeError = expectLater(active, throwsA(_lost));
      final queuedError = expectLater(queued, throwsA(_lost));
      await platform.waitForWrites(1);
      final oldCallback = platform.onValueChange!;

      platform.loseConnection();
      expect(old.isDisconnected, isTrue);
      await Future.wait([activeError, queuedError]);
      expect(platform.writes, hasLength(1));
      expect(await manager.devices, isEmpty);

      final fresh = await connect();
      final next = fresh.sendOperation(_ByteOperation(4));
      await platform.waitForWrites(2);
      oldCallback(
          _device.id, _device.deviceInfo.notifyCharacteristicKey, Uint8List.fromList([5, 0, 0, 0, 1, 99]), null);
      platform.response([5, 0, 0, 0, 1, 42]);
      expect(await next, 42);
      await old.disconnect();
      expect(fresh.isDisconnected, isFalse);
    });

    test("public BLE interface reports a lost operation and reconnects", () async {
      final ledger = LedgerInterface.ble(onPermissionRequest: (_) async => true);
      try {
        final connection = await ledger.connect(_device);
        final active = connection.sendOperation(_ByteOperation(1));
        final failure = expectLater(active, throwsA(_lost));
        await platform.waitForWrites(1);
        platform.loseConnection();
        await failure;
        final fresh = await ledger.connect(_device);
        final next = fresh.sendOperation(_ByteOperation(2));
        await platform.waitForWrites(2);
        platform.response([5, 0, 0, 0, 1, 5]);
        expect(await next, 5);
      } finally {
        await ledger.dispose();
      }
    });

    test("disposing during discovery retires the attempt before a replacement connects", () async {
      platform.discoveryGate = Completer<void>();
      platform.discoveryEntered = Completer<void>();
      final oldAttempt = manager.connect(_device);
      final oldFailure = expectLater(oldAttempt, throwsA(_lost));
      await platform.discoveryEntered!.future;
      expect(platform.connected, isTrue);

      final disposing = manager.dispose();
      await oldFailure;
      final replacement = LedgerBleConnectionManager(onPermissionRequest: (_) async => true);
      manager = replacement;
      final newAttempt = replacement.connect(_device);
      await Future<void>.delayed(Duration.zero);
      expect(platform.connectCalls, 1);
      expect(platform.disconnectCalls, 0);

      platform.discoveryGate!.complete();
      platform.discoveryGate = null;
      await Future.wait([disposing, newAttempt]);
      expect(platform.disconnectCalls, 1);
      expect(platform.connectCalls, 2);
      final connection = LedgerConnection(replacement, _device);
      final next = connection.sendOperation(_ByteOperation(2));
      await platform.waitForWrites(1);
      platform.response([5, 0, 0, 0, 1, 7]);
      expect(await next, 7);
    });

    testWidgets("stalled discovery fails replacement closed and leaves retirement pending", (tester) async {
      platform.discoveryGate = Completer<void>();
      platform.discoveryEntered = Completer<void>();
      final oldAttempt = manager.connect(_device);
      final oldFailure = expectLater(oldAttempt, throwsA(_lost));
      await platform.discoveryEntered!.future;
      final disposing = manager.dispose();
      await oldFailure;
      final replacement = LedgerBleConnectionManager(onPermissionRequest: (_) async => true);
      manager = replacement;
      final failure = expectLater(replacement.connect(_device), throwsA(isA<EstablishConnectionException>()));
      try {
        await tester.pump();
        await tester.pump(const Duration(seconds: 5));
        await Future.wait([disposing, failure]);
        expect(platform.connectCalls, 1);
        expect(platform.disconnectCalls, 0);
      } finally {
        platform.discoveryGate!.complete();
        platform.discoveryGate = null;
      }
      await tester.pump();
      await replacement.connect(_device);
      expect(platform.disconnectCalls, 1);
      expect(platform.connectCalls, 2);
      final connection = LedgerConnection(replacement, _device);
      final next = connection.sendOperation(_ByteOperation(2));
      await platform.waitForWrites(1);
      platform.response([5, 0, 0, 0, 1, 7]);
      expect(await next, 7);
    });

    test("concurrent connection attempts retire the old attempt before starting the new one", () async {
      platform.discoveryGate = Completer<void>();
      platform.discoveryEntered = Completer<void>();
      final first = manager.connect(_device);
      final failure = expectLater(first, throwsA(_lost));
      await platform.discoveryEntered!.future;
      final second = manager.connect(_device);
      await failure;
      await Future<void>.delayed(Duration.zero);
      expect(platform.connectCalls, 1);
      platform.discoveryGate!.complete();
      platform.discoveryGate = null;
      await second;
      expect(platform.disconnectCalls, 1);
      expect(platform.connectCalls, 2);
      final connection = LedgerConnection(manager, _device);
      final next = connection.sendOperation(_ByteOperation(3));
      await platform.waitForWrites(1);
      platform.response([5, 0, 0, 0, 1, 8]);
      expect(await next, 8);
    });

    test("old interface disposal cannot clear replacement connection callbacks", () async {
      final old = LedgerInterface.ble(onPermissionRequest: (_) async => true);
      final oldConnection = await old.connect(_device);
      platform.disconnectGate = Completer<void>();
      platform.disconnectEntered = Completer<void>();
      final disposing = old.dispose();
      await platform.disconnectEntered!.future;
      final replacement = LedgerInterface.ble(onPermissionRequest: (_) async => true);
      platform.disconnectGate!.complete();
      platform.disconnectGate = null;
      await disposing;
      expect(oldConnection.isDisconnected, isTrue);
      final fresh = await replacement.connect(_device);
      try {
        await old.dispose();
        expect(identical(LedgerInterface.ble(onPermissionRequest: (_) async => true), replacement), isTrue);
        final pending = fresh.sendOperation(_ByteOperation(1));
        final failure = expectLater(pending, throwsA(_lost));
        await platform.waitForWrites(1);
        platform.loseConnection();
        await failure;
        expect(fresh.isDisconnected, isTrue);
      } finally {
        await replacement.dispose();
      }
    });

    test("a connection created for an old generation cannot use a new session", () async {
      final oldGeneration = await manager.connectSession(_device);
      platform.loseConnection();
      final fresh = await connect();
      final old = LedgerConnection(manager, _device, bleSession: oldGeneration);
      expect(old.isDisconnected, isTrue);
      await expectLater(old.sendOperation(_ByteOperation(1)), throwsA(isA<DeviceNotConnectedException>()));
      await old.disconnect();
      final next = fresh.sendOperation(_ByteOperation(2));
      await platform.waitForWrites(1);
      platform.response([5, 0, 0, 0, 1, 4]);
      expect(await next, 4);
    });

    test("explicit disconnect fails a waiting APDU and nested queued APDUs", () async {
      final connection = await connect();
      final active = connection.sendOperation(const _ParallelOperations());
      final queued = connection.sendOperation(_ByteOperation(3));
      final activeError = expectLater(active, throwsA(_lost));
      final queuedError = expectLater(queued, throwsA(_lost));
      await platform.waitForWrites(1);
      final disconnecting = connection.disconnect();
      await Future.wait([activeError, queuedError, disconnecting]);
      expect(platform.writes, hasLength(1));
      expect(connection.isDisconnected, isTrue);
    });

    test("manager dispose terminates an active request", () async {
      final connection = await connect();
      final active = connection.sendOperation(_ByteOperation(1));
      final error = expectLater(active, throwsA(_lost));
      await platform.waitForWrites(1);
      await Future.wait([manager.dispose(), error]);
      expect(connection.isDisconnected, isTrue);
    });

    test("reconnect waits for a submitted write to settle", () async {
      final connection = await connect();
      platform.writeGate = Completer<void>();
      final active = connection.sendOperation(_ByteOperation(1));
      final failure = expectLater(active, throwsA(_lost));
      await platform.waitForWrites(1);
      platform.loseConnection();
      await failure;

      final reconnect = connect();
      await Future<void>.delayed(Duration.zero);
      expect(platform.connectCalls, 1);
      platform.writeGate!.complete();
      platform.writeGate = null;
      final fresh = await reconnect;
      final next = fresh.sendOperation(_ByteOperation(2));
      await platform.waitForWrites(2);
      platform.response([5, 0, 0, 0, 1, 5]);
      expect(await next, 5);
    });

    testWidgets("stalled disconnect state check bounds reconnect without releasing its barrier", (tester) async {
      final connection = await connect();
      platform.stateGate = Completer<void>();
      platform.stateEntered = Completer<void>();
      final disconnecting = expectLater(
        connection.disconnect(),
        throwsA(isA<DisposeException>().having((e) => e.cause, "cause", isA<TimeoutException>())),
      );
      await platform.stateEntered!.future;
      try {
        final firstFailure = expectLater(connect(), throwsA(isA<EstablishConnectionException>()));
        await tester.pump();
        await tester.pump(const Duration(seconds: 5));
        await Future.wait([firstFailure, disconnecting]);
        expect(platform.connectCalls, 1);

        await manager.dispose();
        manager = LedgerBleConnectionManager(onPermissionRequest: (_) async => true);
        final secondFailure = expectLater(connect(), throwsA(isA<EstablishConnectionException>()));
        await tester.pump();
        await tester.pump(const Duration(seconds: 5));
        await secondFailure;
        expect(platform.connectCalls, 1);
        expect(platform.disconnectCalls, 0);
      } finally {
        platform.stateGate!.complete();
        platform.stateGate = null;
      }
      await tester.pump();
      final fresh = await connect();
      final next = fresh.sendOperation(_ByteOperation(2));
      await platform.waitForWrites(1);
      platform.response([5, 0, 0, 0, 1, 5]);
      expect(await next, 5);
    });

    test("explicit disconnect fails a request before a blocked write settles", () async {
      final connection = await connect();
      platform.writeGate = Completer<void>();
      final active = connection.sendOperation(_ByteOperation(1));
      final failure = expectLater(active, throwsA(_lost));
      await platform.waitForWrites(1);
      final disconnecting = connection.disconnect();
      await failure;
      final reconnect = connect();
      platform.writeGate!.complete();
      platform.writeGate = null;
      await disconnecting;
      final fresh = await reconnect;
      final next = fresh.sendOperation(_ByteOperation(2));
      await platform.waitForWrites(2);
      platform.response([5, 0, 0, 0, 1, 7]);
      expect(await next, 7);
    });

    test("reconnect does not reuse a link when plugin disconnect fails", () async {
      final connection = await connect();
      platform.failDisconnect = true;
      await connection.disconnect();
      expect(platform.connected, isTrue);

      await manager.dispose();
      manager = LedgerBleConnectionManager(onPermissionRequest: (_) async => true);
      await expectLater(connect(), throwsA(_lost));
      expect(platform.connectCalls, 1);
      expect(platform.writes, isEmpty);

      platform.failConnectionState = true;
      await expectLater(connect(), throwsA(isA<EstablishConnectionException>()));
      expect(platform.connectCalls, 1);
      platform.failConnectionState = false;
      platform.failDisconnect = false;
      platform.loseConnection();
      final fresh = await connect();
      final next = fresh.sendOperation(_ByteOperation(2));
      await platform.waitForWrites(1);
      platform.response([5, 0, 0, 0, 1, 7]);
      expect(await next, 7);
    });

    test("response decoding from a retired session cannot complete a new request", () async {
      final connection = await connect();
      final transformer = _BlockingTransformer();
      final operation = _ReadProbe();
      final active = connection.sendOperation(operation, transformer: transformer);
      final failure = expectLater(active, throwsA(_lost));
      await platform.waitForWrites(1);
      platform.response([5, 0, 0, 0, 1, 1]);
      await transformer.entered.future;
      platform.loseConnection();
      await failure;
      final fresh = await connect();
      final next = fresh.sendOperation(_ByteOperation(2));
      await platform.waitForWrites(2);
      transformer.release.complete();
      await Future<void>.delayed(Duration.zero);
      expect(operation.reads, 0);
      platform.response([5, 0, 0, 0, 1, 9]);
      expect(await next, 9);
    });

    test("partial response from a lost session cannot contaminate a reconnect", () async {
      final connection = await connect();
      final active = connection.sendOperation(_ByteOperation(1));
      final failure = expectLater(active, throwsA(_lost));
      await platform.waitForWrites(1);
      platform.response([5, 0, 0, 0, 2, 1]);
      final oldCallback = platform.onValueChange!;
      platform.loseConnection();
      await failure;
      final fresh = await connect();
      final next = fresh.sendOperation(_ByteOperation(2));
      await platform.waitForWrites(2);
      oldCallback(_device.id, _device.deviceInfo.notifyCharacteristicKey, Uint8List.fromList([5, 0, 1, 2]), null);
      platform.response([5, 0, 0, 0, 1, 3]);
      expect(await next, 3);
    });

    test("an old operation completing its write preparation cannot send after reconnect", () async {
      final connection = await connect();
      final operation = _SlowWriteOperation();
      final active = connection.sendOperation(operation);
      final failure = expectLater(active, throwsA(_lost));
      await operation.entered.future;
      platform.loseConnection();
      await failure;
      final fresh = await connect();
      operation.release.complete();
      await Future<void>.delayed(Duration.zero);
      expect(platform.writes, isEmpty);
      final next = fresh.sendOperation(_ByteOperation(2));
      await platform.waitForWrites(1);
      platform.response([5, 0, 0, 0, 1, 3]);
      expect(await next, 3);
    });

    test("write failure removes the request and permits the next APDU", () async {
      final connection = await connect();
      platform.writeError = StateError("write failed");
      final first = connection.sendOperation(_ByteOperation(1));
      await expectLater(first, throwsStateError);
      platform.writeError = null;
      final second = connection.sendOperation(_ByteOperation(2));
      await platform.waitForWrites(2);
      platform.response([5, 0, 0, 0, 1, 4]);
      expect(await second, 4);
    });

    test("BLE write timeout terminates the session and cancels queued APDUs", () async {
      final connection = await connect();
      platform.writeGate = Completer<void>();
      platform.timeoutWrite = true;
      final active = connection.sendOperation(_ByteOperation(1));
      final queued = connection.sendOperation(_ByteOperation(2));
      final activeFailure = expectLater(active, throwsA(_lost));
      final queuedFailure = expectLater(queued, throwsA(_lost));
      await platform.waitForWrites(1);
      platform.writeGate!.complete();
      await Future.wait([activeFailure, queuedFailure]);
      expect(connection.isDisconnected, isTrue);
      expect(platform.writes, hasLength(1));
      platform.writeGate = null;
      platform.timeoutWrite = false;
      final fresh = await connect();
      final next = fresh.sendOperation(_ByteOperation(3));
      await platform.waitForWrites(2);
      platform.response([5, 0, 0, 0, 1, 6]);
      expect(await next, 6);
    });

    test("response waits for the submitted write before completing", () async {
      final connection = await connect();
      platform.writeGate = Completer<void>();
      var completed = false;
      final first = connection.sendOperation(_ByteOperation(1));
      unawaited(first.then<void>((_) => completed = true));
      final second = connection.sendOperation(_ByteOperation(2));
      await platform.waitForWrites(1);
      platform.response([5, 0, 0, 0, 1, 4]);
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      expect(platform.writes, hasLength(1));

      platform.writeGate!.complete();
      platform.writeGate = null;
      expect(await first, 4);
      await platform.waitForWrites(2);
      platform.response([5, 0, 0, 0, 1, 5]);
      expect(await second, 5);
    });

    test("malformed response cannot release the queue before the write settles", () async {
      final connection = await connect();
      platform.writeGate = Completer<void>();
      final first = connection.sendOperation(_ByteOperation(1));
      final firstFailure = expectLater(first, throwsA(isA<UnexpectedDataPacketException>()));
      final second = connection.sendOperation(_ByteOperation(2));
      await platform.waitForWrites(1);
      platform.response([5, 0]);
      await Future<void>.delayed(Duration.zero);
      expect(platform.writes, hasLength(1));
      platform.writeGate!.complete();
      platform.writeGate = null;
      await firstFailure;
      await platform.waitForWrites(2);
      platform.response([5, 0, 0, 0, 1, 5]);
      expect(await second, 5);
    });

    test("response before a write timeout cannot release the queue", () async {
      final connection = await connect();
      platform.writeGate = Completer<void>();
      platform.timeoutWrite = true;
      final first = connection.sendOperation(_ByteOperation(1));
      final second = connection.sendOperation(_ByteOperation(2));
      final firstFailure = expectLater(first, throwsA(_lost));
      final secondFailure = expectLater(second, throwsA(_lost));
      await platform.waitForWrites(1);
      platform.response([5, 0, 0, 0, 1, 4]);
      await Future<void>.delayed(Duration.zero);
      expect(platform.writes, hasLength(1));

      platform.writeGate!.complete();
      await Future.wait([firstFailure, secondFailure]);
      expect(connection.isDisconnected, isTrue);
      expect(platform.writes, hasLength(1));
      platform.writeGate = null;
      platform.timeoutWrite = false;
      final fresh = await connect();
      final next = fresh.sendOperation(_ByteOperation(3));
      await platform.waitForWrites(2);
      platform.response([5, 0, 0, 0, 1, 6]);
      expect(await next, 6);
    });

    testWidgets("native write timeout retires even after a complete response", (tester) async {
      final connection = await connect();
      platform.writeGate = Completer<void>();
      final first = connection.sendOperation(_ByteOperation(1));
      final second = connection.sendOperation(_ByteOperation(2));
      final firstFailure = expectLater(first, throwsA(_lost));
      final secondFailure = expectLater(second, throwsA(_lost));
      await platform.waitForWrites(1);
      try {
        platform.response([5, 0, 0, 0, 1, 4]);
        await tester.pump();
        expect(platform.writes, hasLength(1));
        await tester.pump(const Duration(seconds: 10));
        await Future.wait([firstFailure, secondFailure]);
        expect(connection.isDisconnected, isTrue);
        expect(platform.writes, hasLength(1));
      } finally {
        platform.writeGate!.complete();
        platform.writeGate = null;
      }
      await tester.pump();
    });

    test("device rejection remains a device error and does not poison the queue", () async {
      final connection = await connect();
      final first = connection.sendOperation(_RejectedOperation());
      final failure =
          expectLater(first, throwsA(isA<LedgerDeviceException>().having((e) => e.errorCode, "code", 0x6985)));
      await platform.waitForWrites(1);
      platform.response([5, 0, 0, 0, 1, 0]);
      await failure;
      final second = connection.sendOperation(_ByteOperation(2));
      await platform.waitForWrites(2);
      platform.response([5, 0, 0, 0, 1, 6]);
      expect(await second, 6);
    });

    test("multi APDU operation stays atomic relative to another operation", () async {
      final connection = await connect();
      final first = connection.sendOperation(const _TwoOperations());
      final second = connection.sendOperation(_ByteOperation(3));
      await platform.waitForWrites(1);
      expect(platform.writes.single.last, 1);
      platform.response([5, 0, 0, 0, 1, 11]);
      await platform.waitForWrites(2);
      expect(platform.writes[1].last, 2);
      platform.response([5, 0, 0, 0, 1, 22]);
      expect(await first, [11, 22]);
      await platform.waitForWrites(3);
      expect(platform.writes[2].last, 3);
      platform.response([5, 0, 0, 0, 1, 33]);
      expect(await second, 33);
    });

    test("malformed response fails its request and clears partial data", () async {
      final connection = await connect();
      final first = connection.sendOperation(_ByteOperation(1));
      final failure = expectLater(first, throwsA(isA<UnexpectedDataPacketException>()));
      await platform.waitForWrites(1);
      platform.response([5, 0, 0, 0, 2, 1]);
      platform.response([5, 0]);
      await failure;
      final second = connection.sendOperation(_ByteOperation(2));
      await platform.waitForWrites(2);
      platform.response([5, 0, 0, 0, 1, 8]);
      expect(await second, 8);
    });

    test("response exceeding its declared length fails instead of hanging", () async {
      final connection = await connect();
      final response = connection.sendOperation(_ByteOperation(1));
      final failure = expectLater(
        response,
        throwsA(isA<UnexpectedDataPacketException>().having(
          (e) => e.reason,
          "reason",
          UnexpectedDataPacketReason.dataLengthExceeded,
        )),
      );
      await platform.waitForWrites(1);
      platform.response([5, 0, 0, 0, 1, 1, 2]);
      await failure;
    });
  });

  test("USB operation still exchanges a framed APDU", () async {
    final previous = LedgerUsbPlatform.instance;
    final platform = _UsbPlatform();
    LedgerUsbPlatform.instance = platform;
    try {
      final manager = LedgerUsbManager();
      const device = LedgerDevice(
        id: "usb-test",
        name: "test",
        connectionType: ConnectionType.usb,
        deviceInfo: LedgerDeviceType.nanoX,
      );
      final connection = LedgerConnection(manager, device);
      expect(await connection.sendOperation(_ByteOperation(7)), 42);
      expect(platform.lastWrite![7], 7);
      await connection.disconnect();
      await manager.dispose();
    } finally {
      LedgerUsbPlatform.instance = previous;
    }
  });

  test("queue timeout completes active and queued requests without starting the next", () async {
    final queue = RequestQueue(inFlightTimeout: Duration.zero);
    final blocked = Completer<int>();
    var startedNext = false;
    final first = queue.enqueueRequest(() => blocked.future);
    final second = queue.enqueueRequest(() {
      startedNext = true;
      return 2;
    });
    await Future.wait([
      expectLater(first, throwsA(isA<TimeoutException>())),
      expectLater(second, throwsA(isA<TimeoutException>())),
    ]);
    expect(startedNext, isFalse);
    blocked.complete(1);
  });
}
