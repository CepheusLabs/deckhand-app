import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'flash_transports.dart';

typedef DeckhandFirmwareFetcher = Future<Uint8List> Function(Uri uri);

abstract interface class BrowserDeviceTransport {
  Future<void> openSerial({
    required Map<String, Object?> filters,
    required int baudRate,
  });

  Future<void> writeSerial(Uint8List bytes);

  Future<void> openUsb({required Map<String, Object?> filters});

  Future<void> usbControlTransferOut({
    required String requestType,
    required String recipient,
    required int request,
    required int value,
    required int index,
    required Uint8List bytes,
  });

  Future<void> openHid({required Map<String, Object?> filters});

  Future<void> hidSendReport({required int reportId, required Uint8List bytes});

  Future<void> close();
}

abstract class BrowserDeviceFlashDelegate implements BrowserFlashDelegate {
  BrowserDeviceFlashDelegate({
    required BrowserDeviceTransport transport,
    DeckhandFirmwareFetcher? firmwareFetcher,
  }) : _transport = transport,
       _firmwareFetcher = firmwareFetcher;

  final BrowserDeviceTransport _transport;
  final DeckhandFirmwareFetcher? _firmwareFetcher;

  Future<Uint8List> firmwareBytesFor(DeckhandTransportOperation operation) {
    final bytes = operation.firmwareBytes;
    if (bytes != null) {
      return Future.value(bytes);
    }
    final uri = operation.firmwareUrl;
    final fetcher = _firmwareFetcher;
    if (uri != null && fetcher != null) {
      return fetcher(uri);
    }
    throw const DeckhandTransportException(
      'firmware bytes or a firmware fetcher are required',
    );
  }

  Future<void> closeTransport() => _transport.close();
}

class WebSerialBootloaderDelegate extends BrowserDeviceFlashDelegate {
  WebSerialBootloaderDelegate({
    required super.transport,
    super.firmwareFetcher,
  });

  @override
  bool canHandle(String requirement) {
    return requirement == 'webserial.bootloader';
  }

  @override
  Stream<DeckhandTransportEvent> execute(
    DeckhandTransportOperation operation,
  ) async* {
    final config = _map(operation.step['webserial']);
    final firmware = await firmwareBytesFor(operation);
    final chunkSize = _positiveInt(config['chunk_size'], fallback: 1024);
    final baudRate = _positiveInt(config['baud_rate'], fallback: 115200);
    yield const DeckhandTransportEvent(
      phase: DeckhandTransportPhase.connecting,
      percent: 0,
      message: 'requesting serial bootloader',
    );
    await _transport.openSerial(
      filters: _map(config['filters']),
      baudRate: baudRate,
    );
    final enterBootloader = _bytes(config['enter_bootloader_bytes']);
    if (enterBootloader.isNotEmpty) {
      await _transport.writeSerial(enterBootloader);
    }
    var written = 0;
    try {
      await for (final chunk in _chunks(firmware, chunkSize)) {
        await _transport.writeSerial(chunk);
        written += chunk.length;
        yield DeckhandTransportEvent(
          phase: DeckhandTransportPhase.flashing,
          percent: written / firmware.length,
          bytesDone: written,
          bytesTotal: firmware.length,
        );
      }
      yield const DeckhandTransportEvent(
        phase: DeckhandTransportPhase.done,
        percent: 1,
        message: 'serial bootloader flash complete',
      );
    } finally {
      await closeTransport();
    }
  }
}

class WebUsbDfuDelegate extends BrowserDeviceFlashDelegate {
  WebUsbDfuDelegate({required super.transport, super.firmwareFetcher});

  @override
  bool canHandle(String requirement) => requirement == 'webusb.dfu';

  @override
  Stream<DeckhandTransportEvent> execute(
    DeckhandTransportOperation operation,
  ) async* {
    final config = _map(operation.step['webusb']);
    final firmware = await firmwareBytesFor(operation);
    final chunkSize = _positiveInt(config['chunk_size'], fallback: 2048);
    final request = _positiveInt(config['request'], fallback: 1);
    final valueBase = _positiveInt(config['value'], fallback: 0);
    final index = _positiveInt(config['index'], fallback: 0);
    final requestType = config['request_type']?.toString() ?? 'vendor';
    final recipient = config['recipient']?.toString() ?? 'interface';
    yield const DeckhandTransportEvent(
      phase: DeckhandTransportPhase.connecting,
      percent: 0,
      message: 'requesting USB DFU device',
    );
    await _transport.openUsb(filters: _map(config['filters']));
    var written = 0;
    var block = 0;
    try {
      await for (final chunk in _chunks(firmware, chunkSize)) {
        await _transport.usbControlTransferOut(
          requestType: requestType,
          recipient: recipient,
          request: request,
          value: valueBase + block,
          index: index,
          bytes: chunk,
        );
        written += chunk.length;
        block += 1;
        yield DeckhandTransportEvent(
          phase: DeckhandTransportPhase.flashing,
          percent: written / firmware.length,
          bytesDone: written,
          bytesTotal: firmware.length,
        );
      }
      yield const DeckhandTransportEvent(
        phase: DeckhandTransportPhase.done,
        percent: 1,
        message: 'USB DFU flash complete',
      );
    } finally {
      await closeTransport();
    }
  }
}

class WebHidReportDelegate extends BrowserDeviceFlashDelegate {
  WebHidReportDelegate({required super.transport, super.firmwareFetcher});

  @override
  bool canHandle(String requirement) {
    return requirement == 'webhid.report' || requirement == 'webhid.keyboard';
  }

  @override
  Stream<DeckhandTransportEvent> execute(
    DeckhandTransportOperation operation,
  ) async* {
    final config = _map(operation.step['webhid']);
    final firmware = await firmwareBytesFor(operation);
    final chunkSize = _positiveInt(config['chunk_size'], fallback: 64);
    final reportId = _positiveInt(config['report_id'], fallback: 0);
    yield const DeckhandTransportEvent(
      phase: DeckhandTransportPhase.connecting,
      percent: 0,
      message: 'requesting HID device',
    );
    await _transport.openHid(filters: _map(config['filters']));
    var written = 0;
    try {
      await for (final chunk in _chunks(firmware, chunkSize)) {
        await _transport.hidSendReport(reportId: reportId, bytes: chunk);
        written += chunk.length;
        yield DeckhandTransportEvent(
          phase: DeckhandTransportPhase.flashing,
          percent: written / firmware.length,
          bytesDone: written,
          bytesTotal: firmware.length,
        );
      }
      yield const DeckhandTransportEvent(
        phase: DeckhandTransportPhase.done,
        percent: 1,
        message: 'HID flash complete',
      );
    } finally {
      await closeTransport();
    }
  }
}

Map<String, Object?> _map(Object? raw) {
  if (raw is Map) {
    return raw.cast<String, Object?>();
  }
  return const <String, Object?>{};
}

int _positiveInt(Object? raw, {required int fallback}) {
  final value = raw is int
      ? raw
      : raw is num
      ? raw.round()
      : int.tryParse(raw?.toString() ?? '');
  return value == null || value <= 0 ? fallback : value;
}

Uint8List _bytes(Object? raw) {
  if (raw == null) {
    return Uint8List(0);
  }
  if (raw is Uint8List) {
    return raw;
  }
  if (raw is List) {
    return Uint8List.fromList([
      for (final value in raw)
        if (value is int) value & 0xff,
    ]);
  }
  final text = raw.toString().trim();
  if (text.isEmpty) {
    return Uint8List(0);
  }
  if (text.startsWith('base64:')) {
    return Uint8List.fromList(base64Decode(text.substring('base64:'.length)));
  }
  final hex = text.startsWith('hex:') ? text.substring('hex:'.length) : text;
  final cleaned = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  if (cleaned.length.isOdd) {
    throw const DeckhandTransportException('hex byte payload has odd length');
  }
  return Uint8List.fromList([
    for (var i = 0; i < cleaned.length; i += 2)
      int.parse(cleaned.substring(i, i + 2), radix: 16),
  ]);
}

Stream<Uint8List> _chunks(Uint8List bytes, int chunkSize) async* {
  if (bytes.isEmpty) {
    return;
  }
  for (var offset = 0; offset < bytes.length; offset += chunkSize) {
    final end = offset + chunkSize > bytes.length
        ? bytes.length
        : offset + chunkSize;
    yield Uint8List.sublistView(bytes, offset, end);
  }
}
