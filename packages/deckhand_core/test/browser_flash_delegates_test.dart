import 'dart:typed_data';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('browser flash delegates', () {
    test('WebSerial writes bootloader bytes then firmware chunks', () async {
      final transport = _FakeBrowserDeviceTransport();
      final delegate = WebSerialBootloaderDelegate(transport: transport);

      final events = await delegate
          .execute(
            DeckhandTransportOperation(
              requirement: 'webserial.bootloader',
              step: const {
                'webserial': {
                  'baud_rate': 57600,
                  'chunk_size': 2,
                  'enter_bootloader_bytes': 'hex:55aa',
                },
              },
              firmwareBytes: Uint8List.fromList([1, 2, 3]),
            ),
          )
          .toList();

      expect(transport.serialOpenBaudRates, [57600]);
      expect(transport.serialWrites.map((b) => b.toList()), [
        [0x55, 0xaa],
        [1, 2],
        [3],
      ]);
      expect(events.last.phase, DeckhandTransportPhase.done);
      expect(transport.closeCount, 1);
    });

    test(
      'WebUSB DFU emits control transfers with incrementing values',
      () async {
        final transport = _FakeBrowserDeviceTransport();
        final delegate = WebUsbDfuDelegate(transport: transport);

        await delegate
            .execute(
              DeckhandTransportOperation(
                requirement: 'webusb.dfu',
                step: const {
                  'webusb': {
                    'request': 7,
                    'value': 10,
                    'index': 2,
                    'chunk_size': 2,
                  },
                },
                firmwareBytes: Uint8List.fromList([1, 2, 3, 4, 5]),
              ),
            )
            .drain<void>();

        expect(transport.usbTransfers.map((t) => t.value), [10, 11, 12]);
        expect(transport.usbTransfers.map((t) => t.bytes.toList()), [
          [1, 2],
          [3, 4],
          [5],
        ]);
      },
    );

    test('WebHID sends firmware chunks as reports', () async {
      final transport = _FakeBrowserDeviceTransport();
      final delegate = WebHidReportDelegate(transport: transport);

      await delegate
          .execute(
            DeckhandTransportOperation(
              requirement: 'webhid.report',
              step: const {
                'webhid': {'report_id': 4, 'chunk_size': 3},
              },
              firmwareBytes: Uint8List.fromList([9, 8, 7, 6]),
            ),
          )
          .drain<void>();

      expect(transport.hidReports.map((r) => r.reportId), [4, 4]);
      expect(transport.hidReports.map((r) => r.bytes.toList()), [
        [9, 8, 7],
        [6],
      ]);
    });
  });
}

class _FakeBrowserDeviceTransport implements BrowserDeviceTransport {
  final serialOpenBaudRates = <int>[];
  final serialWrites = <Uint8List>[];
  final usbTransfers = <_UsbTransfer>[];
  final hidReports = <_HidReport>[];
  var closeCount = 0;

  @override
  Future<void> close() async {
    closeCount += 1;
  }

  @override
  Future<void> hidSendReport({
    required int reportId,
    required Uint8List bytes,
  }) async {
    hidReports.add(_HidReport(reportId, Uint8List.fromList(bytes)));
  }

  @override
  Future<void> openHid({required Map<String, Object?> filters}) async {}

  @override
  Future<void> openSerial({
    required Map<String, Object?> filters,
    required int baudRate,
  }) async {
    serialOpenBaudRates.add(baudRate);
  }

  @override
  Future<void> openUsb({required Map<String, Object?> filters}) async {}

  @override
  Future<void> usbControlTransferOut({
    required String requestType,
    required String recipient,
    required int request,
    required int value,
    required int index,
    required Uint8List bytes,
  }) async {
    usbTransfers.add(_UsbTransfer(value, Uint8List.fromList(bytes)));
  }

  @override
  Future<void> writeSerial(Uint8List bytes) async {
    serialWrites.add(Uint8List.fromList(bytes));
  }
}

class _UsbTransfer {
  const _UsbTransfer(this.value, this.bytes);

  final int value;
  final Uint8List bytes;
}

class _HidReport {
  const _HidReport(this.reportId, this.bytes);

  final int reportId;
  final Uint8List bytes;
}
