<br />
<div align="center">
  <a href="https://www.ledger.com/">
    <img src="https://cdn1.iconfinder.com/data/icons/minicons-4/64/ledger-512.png" width="100"/>
  </a>

<h1 align="center">ledger-flutter-plus</h1>

<p align="center">
    A Flutter plugin to scan, connect & sign transactions using Ledger Nano devices using USB & BLE
    <br />
    <a href="https://pub.dev/documentation/ledger_flutter_plus/latest/"><strong>« Explore the docs »</strong></a>
    <br />
    <br />
    <a href="https://github.com/vespr-wallet/ledger-flutter-plus/issues">Report Bug</a>
    · <a href="https://github.com/vespr-wallet/ledger-flutter-plus/issues">Request Feature</a>
  </p>
</div>
<br/>

---

## Note

This package has been forked from [ledger-flutter](https://github.com/RootSoft/ledger-flutter). Multiple bugs have been fixed, and improvements have been made (such as adding WEB support).

## Overview

Ledger Nano devices are the perfect hardware wallets for managing your crypto & NFTs on the go.
This Flutter plugin makes it easy to find nearby Ledger devices, connect with them and sign transactions over USB and/or BLE.

## Supported devices

|         | BLE                | USB                |
| ------- | ------------------ | ------------------ |
| Android | :heavy_check_mark: | :heavy_check_mark: |
| iOS     | :heavy_check_mark: | :x:                |
| WEB     | :heavy_check_mark: | :heavy_check_mark: |

## Getting started

### Installation

Install the latest version of this package via pub.dev:

```yaml
ledger_flutter_plus: ^latest-version
```

You might want to install additional Ledger App Plugins to support different blockchains. See the [Ledger Plugins](#custom-ledger-app-plugins) section below.

For example, adding Algorand support:

```yaml
ledger_cardano_plus: ^latest-version
```

### Setup

Create a new instance of `LedgerOptions` and pass it to the the `Ledger` constructor.

```dart
final options = LedgerOptions(
  maxScanDuration: const Duration(milliseconds: 5000),
);


final ledgerUsb = Ledger.usb();
final ledgerBle = Ledger.ble(
  onPermissionRequest: (state) {},
)
```

<details>
<summary>Android</summary>

The package uses the following permissions:

- ACCESS_FINE_LOCATION : this permission is needed because old Nexus devices need location services in order to provide reliable scan results
- BLUETOOTH : allows apps to connect to a paired bluetooth device
- BLUETOOTH_ADMIN: allows apps to discover and pair bluetooth devices

Add the following permissions to your `AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>

<!--bibo01 : hardware option-->
<uses-feature android:name="android.hardware.bluetooth" android:required="false"/>
<uses-feature android:name="android.hardware.bluetooth_le" android:required="false"/>

<!-- required for API 18 - 30 -->
<uses-permission
    android:name="android.permission.BLUETOOTH"
    android:maxSdkVersion="30" />
<uses-permission
    android:name="android.permission.BLUETOOTH_ADMIN"
    android:maxSdkVersion="30" />

<!-- API 31+ -->
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission
    android:name="android.permission.BLUETOOTH_SCAN"
    android:usesPermissionFlags="neverForLocation" />
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
```

</details>

<details>
<summary>iOS</summary>

For iOS, it is required you add the following entries to the `Info.plist` file of your app.
It is not allowed to access Core Bluetooth without this.

For more in depth details: [Blog post on iOS bluetooth permissions](https://betterprogramming.pub/handling-ios-13-bluetooth-permissions-26c6a8cbb816?gi=c982a53f1c06)

**iOS13 and higher**

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>This app uses bluetooth to find, connect and sign transactions with your Ledger Nano X</string>
```

**iOS12 and lower**

```xml
<key>NSBluetoothPeripheralUsageDescription</key>
<string>This app uses bluetooth to find, connect and sign transactions with your Ledger Nano X</string>
```

</details>

### Ledger App Plugins

Each blockchain follows it own protocol which needs to be implemented before being able to get public keys & sign transactions.
We introduced the concept of Ledger App Plugins so any developer can easily create and integrate their own Ledger App Plugin and share it with the community.

We added the first support for the Algorand blockchain:

`pubspec.yaml`

```yaml
ledger_cardano_plus: ^latest-version
```

## Usage

### Scanning nearby devices

You can scan for nearby Ledger devices using the `scan()` method. This returns a `Stream` that can be listened to which emits when a new device has been found.

```dart
final subscription = ledger.scan().listen((device) => print(device));
```

Scanning stops once `maxScanDuration` is passed or the `stop()` method is called.
The `maxScanDuration` is the maximum amount of time BLE discovery should run in order to find nearby devices.

```dart
await ledger.stop();
```

#### Permissions

The Ledger Flutter plugin uses [Bluetooth Low Energy]() which requires certain permissions to be handled on both iOS & Android.
The plugin sends a callback every time a permission is required. All you have to do is override the `onPermissionRequest` and let the wonderful [permission_handler](https://pub.dev/packages/permission_handler) package handle the rest.

```dart
final ledger = Ledger(
  options: options,
  onPermissionRequest: (status) async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.location,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
    ].request();

    if (status != BleStatus.ready) {
      return false;
    }

    return statuses.values.where((status) => status.isDenied).isEmpty;
  },
);
```

### Disconnect

Use the connection's `disconnect()` method to close an established connection.

```dart
final connection = await ledger.connect(device);
await connection.disconnect();
```

For BLE, a physical disconnect, explicit disconnect, manager disposal, or BLE
write timeout terminates in-flight and queued operations with
`ConnectionLostException`. The connection's
`isDisconnected` becomes `true`; subsequent operations on it throw
`DeviceNotConnectedException`. Connect again to obtain a new `LedgerConnection`.
Interrupted operations are not automatically retried; decide whether it is safe
to retry after checking the device state. A reconnect may wait for a previously
submitted BLE write to settle.
If cleanup is still pending after the existing five-second connection-state
interval, reconnect fails with `EstablishConnectionException` containing a
`TimeoutException`; the cleanup barrier remains in place for a later retry.
An explicit disconnect that cannot finish cleanup within that interval fails
with `DisposeException` containing the timeout, while cleanup continues.
After a session ends, reconnect requires the BLE platform to report the device
as disconnected; if the link remains connected or its state cannot be checked,
the attempt fails instead of reusing it. This check does not identify delayed
native notifications from an earlier connection.

### Dispose

Always use the `dispose()` method to close all connections and dispose any potential listeners to not leak any resources.

```dart
await ledger.dispose();
```

### LedgerException

Every method might throw a `LedgerException` which contains the message, cause and potential error code.

```dart
try {
  await channel.ledger.connect(device);
} on LedgerException catch (ex) {
  await channel.ledger.disconnect(device);
}
```

## Custom Ledger App Plugins

Each blockchain follows it own [APDU](https://developers.ledger.com/docs/nano-app/application-structure/) protocol which needs to be implemented before being able to get public keys & sign transactions.

Do you want to support another blockchain like Ethereum, then follow the steps below. You can always check the implementation details in [ledger_algorand]().

### 1. Create a new LedgerApp

Create a new class (e.g. `EthereumLedgerApp`) and extend from `LedgerApp`.

```dart
class EthereumLedgerApp extends LedgerApp {
  EthereumLedgerApp(super.ledger);

  @override
  Future<List<String>> getAccounts(LedgerDevice device) async {
    throw UnimplementedError();
  }

  @override
  Future<Uint8List> signTransaction(
    LedgerDevice device,
    Uint8List transaction,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<List<Uint8List>> signTransactions(
    LedgerDevice device,
    List<Uint8List> transactions,
  ) async {
    throw UnimplementedError();
  }
}
```

### 2. Define the Ledger operation

Create a new Operation class (e.g `EthereumPublicKeyOperation`) for every APDU command and extend from `LedgerOperation`.

Follow and implement the APDU protocol for the desired blockchain.

**APDU protocol:**

- [Ethereum](https://github.com/LedgerHQ/app-ethereum/blob/develop/doc/ethapp.adoc)
- [Bitcoin](https://github.com/LedgerHQ/app-bitcoin/blob/master/doc/btc.asc)
- [Algorand](https://github.com/LedgerHQ/app-algorand/blob/develop/docs/APDUSPEC.md)

```dart
class AlgorandPublicKeyOperation extends LedgerOperation<List<String>> {
  final int accountIndex;

  AlgorandPublicKeyOperation({
    this.accountIndex = 0,
  });

  @override
  Future<Uint8List> write(ByteDataWriter writer, int index, int mtu) async {
    writer.writeUint8(0x80); // ALGORAND_CLA
    writer.writeUint8(0x03); // PUBLIC_KEY_INS
    writer.writeUint8(0x00); // P1_FIRST
    writer.writeUint8(0x00); // P2_LAST
    writer.writeUint8(0x04); // ACCOUNT_INDEX_DATA_SIZE

    writer.writeUint32(accountIndex); // Account index as bytearray

    return writer.toBytes();
  }

  @override
  Future<List<String>> read(ByteDataReader reader, int index, int mtu) async {
    return [
      Address(publicKey: reader.read(reader.remainingLength)).encodedAddress,
    ];
  }
}
```

### 3. Implement the LedgerApp

The final step is to use the Ledger client to perform the desired operation on the connected Ledger.
Implement the required methods on the `LedgerApp`.

Note that the interface for the `LedgerApp` might change for different blockchains, so feel free to open a Pull Request.

```dart
@override
Future<List<String>> getAccounts(LedgerDevice device) async {
    return ledger.sendOperation<List<String>>(
      device,
      AlgorandPublicKeyOperation(accountIndex: accountIndex),
    );
}
```

## Contributing

Contributions are what make the open source community such an amazing place to learn, inspire, and create. Any contributions you make are **greatly appreciated**.

If you have a suggestion that would make this better, please fork the repo and create a pull request. You can also simply open an issue with the tag `enhancement`.

1. Fork the Project
2. Create your Feature Branch (`git checkout -b feature/my-feature`)
3. Commit your Changes (`git commit -m 'feat: my new feature`)
4. Push to the Branch (`git push origin feature/my-feature`)
5. Open a Pull Request

Please read our [Contributing guidelines](CONTRIBUTING.md) and try to follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/).

## License

The ledger_flutter_plus SDK is released under the MIT License (MIT). See LICENSE for details.
