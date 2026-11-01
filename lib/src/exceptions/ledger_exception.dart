// ignore_for_file: no_runtimetype_tostring

import "dart:typed_data";

import "../ledger/connection_type.dart";

sealed class LedgerException implements Exception {}

class PermissionException extends LedgerException {
  final ConnectionType connectionType;

  PermissionException({
    required this.connectionType,
  });

  @override
  String toString() => "$runtimeType($connectionType)";
}

class EstablishConnectionException extends LedgerException {
  final ConnectionType connectionType;
  final Object nestedError;

  EstablishConnectionException({
    required this.connectionType,
    required this.nestedError,
  });

  @override
  String toString() => "$runtimeType($connectionType, $nestedError)";
}

class ConnectionLostException extends LedgerException {
  final ConnectionType connectionType;

  ConnectionLostException({
    required this.connectionType,
  });

  @override
  String toString() => "$runtimeType($connectionType)";
}

class LedgerManagerDisposedException extends LedgerException {
  final ConnectionType connectionType;

  LedgerManagerDisposedException(this.connectionType);

  @override
  String toString() => "$runtimeType($connectionType)";
}

class DisposeException extends LedgerException {
  final ConnectionType connectionType;
  final Object? cause;

  DisposeException({
    required this.connectionType,
    required this.cause,
  });

  @override
  String toString() => "$runtimeType($connectionType, $cause)";
}

class DeviceNotConnectedException extends LedgerException {
  final ConnectionType connectionType;
  final String requestedOperation;

  DeviceNotConnectedException({
    required this.connectionType,
    required this.requestedOperation,
  });

  @override
  String toString() => "$runtimeType($connectionType, $requestedOperation)";
}

class ServiceNotSupportedException extends LedgerException {
  final ConnectionType connectionType;
  final String message;
  final Object? nestedError;

  ServiceNotSupportedException({
    required this.connectionType,
    required this.message,
    this.nestedError,
  });

  @override
  String toString() => "$runtimeType($connectionType, $message)\n$nestedError";
}

class LedgerDeviceException extends LedgerException {
  final String message;
  final Object? cause;
  final int errorCode;
  final ConnectionType connectionType;

  LedgerDeviceException({
    this.message = "",
    this.cause,
    this.errorCode = 0x6F00,
    required this.connectionType,
  });

  @override
  String toString() => "$runtimeType($connectionType, $errorCode, $message)\n$cause";
}

class UnexpectedDataPacketException extends LedgerException {
  final Uint8List? data;
  final UnexpectedDataPacketReason reason;
  final ConnectionType connectionType;

  UnexpectedDataPacketException({
    this.data,
    required this.reason,
    required this.connectionType,
  });

  @override
  String toString() => "$runtimeType($connectionType, $reason)\n$data";
}

enum UnexpectedDataPacketReason {
  tooShortLength,
  dataLengthExceeded,
  indexAlreadySet,
  dataLengthAlreadySet,
  // we received a data packet without a pending request
  // this may happen if there are multiple [LedgerConnection]
  // instances for the same device, since the wrong instance
  // may have received the data packet. You should not have
  // P.s. you should not have multiple [LedgerConnection] instances for the same device
  receivedLedgerDataWithNoPendingRequest,
}
