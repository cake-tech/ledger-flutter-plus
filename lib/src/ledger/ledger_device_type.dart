enum LedgerDeviceType {
  blue(
    usbOnly: true,
    productIdMM: 0x00,
    serviceId: "",
    writeCharacteristicKey: "",
    notifyCharacteristicKey: "",
  ),
  nanoS(
    usbOnly: true,
    productIdMM: 0x10,
    serviceId: "",
    writeCharacteristicKey: "",
    notifyCharacteristicKey: "",
  ),
  nanoX(
    usbOnly: false,
    productIdMM: 0x40,
    serviceId: "13D63400-2C97-0004-0000-4C6564676572",
    writeCharacteristicKey: "13D63400-2C97-0004-0002-4C6564676572",
    notifyCharacteristicKey: "13D63400-2C97-0004-0001-4C6564676572",
  ),
  nanoSP(
    usbOnly: true,
    productIdMM: 0x50,
    serviceId: "",
    writeCharacteristicKey: "",
    notifyCharacteristicKey: "",
  ),
  stax(
    usbOnly: false,
    productIdMM: 0x60,
    serviceId: "13D63400-2C97-6004-0000-4C6564676572",
    writeCharacteristicKey: "13d63400-2c97-6004-0002-4c6564676572",
    notifyCharacteristicKey: "13D63400-2C97-6004-0001-4C6564676572",
  ),
  flex(
    usbOnly: false,
    productIdMM: 0x70,
    serviceId: "13D63400-2C97-3004-0000-4C6564676572",
    writeCharacteristicKey: "13d63400-2c97-3004-0002-4c6564676572",
    notifyCharacteristicKey: "13D63400-2C97-3004-0001-4C6564676572",
  ),
  nanoGen5(
    usbOnly: false,
    productIdMM: 0x80,
    serviceId: "13D63400-2C97-8004-0000-4C6564676572",
    writeCharacteristicKey: "13D63400-2C97-8004-0002-4C6564676572",
    notifyCharacteristicKey: "13D63400-2C97-8004-0001-4C6564676572",
  );

  static List<LedgerDeviceType> get ble => values.where((e) => !e.usbOnly).toList();

  const LedgerDeviceType({
    required this.usbOnly,
    required this.productIdMM,
    required this.serviceId,
    required this.writeCharacteristicKey,
    required this.notifyCharacteristicKey,
  });

  final String serviceId;
  final String writeCharacteristicKey;
  final String notifyCharacteristicKey;
  final bool usbOnly;
  final int productIdMM;
}
