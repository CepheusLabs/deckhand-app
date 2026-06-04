import 'dart:typed_data';

import 'package:deckhand_core/deckhand_web_core.dart';

class DeckhandBrowserDeviceTransport implements BrowserDeviceTransport {
  const DeckhandBrowserDeviceTransport();

  @override
  Future<void> close() async {}

  @override
  Future<void> hidSendReport({
    required int reportId,
    required Uint8List bytes,
  }) {
    throw const DeckhandTransportException(
      'WebHID is only available in the browser build.',
    );
  }

  @override
  Future<void> openHid({required Map<String, Object?> filters}) {
    throw const DeckhandTransportException(
      'WebHID is only available in the browser build.',
    );
  }

  @override
  Future<void> openSerial({
    required Map<String, Object?> filters,
    required int baudRate,
  }) {
    throw const DeckhandTransportException(
      'WebSerial is only available in the browser build.',
    );
  }

  @override
  Future<void> openUsb({required Map<String, Object?> filters}) {
    throw const DeckhandTransportException(
      'WebUSB is only available in the browser build.',
    );
  }

  @override
  Future<void> usbControlTransferOut({
    required String requestType,
    required String recipient,
    required int request,
    required int value,
    required int index,
    required Uint8List bytes,
  }) {
    throw const DeckhandTransportException(
      'WebUSB is only available in the browser build.',
    );
  }

  @override
  Future<void> writeSerial(Uint8List bytes) {
    throw const DeckhandTransportException(
      'WebSerial is only available in the browser build.',
    );
  }
}
