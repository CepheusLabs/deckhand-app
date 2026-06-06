import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:deckhand_core/deckhand_web_core.dart';

class DeckhandBrowserDeviceTransport implements BrowserDeviceTransport {
  JSObject? _serialPort;
  JSObject? _usbDevice;
  JSObject? _hidDevice;

  @override
  Future<void> openSerial({
    required Map<String, Object?> filters,
    required int baudRate,
  }) async {
    final serial = _navigatorCapability('serial', 'WebSerial');
    final port = await serial
        .callMethodVarArgs<JSPromise<JSObject>>('requestPort'.toJS, [
          _requestOptions(filters),
        ])
        .toDart;
    await port
        .callMethodVarArgs<JSPromise<JSAny?>>('open'.toJS, [
          {'baudRate': baudRate}.jsify(),
        ])
        .toDart;
    _serialPort = port;
  }

  @override
  Future<void> writeSerial(Uint8List bytes) async {
    final port = _serialPort;
    if (port == null) {
      throw const DeckhandTransportException('Serial port is not open.');
    }
    final writable = port.getProperty<JSObject?>('writable'.toJS);
    if (writable == null) {
      throw const DeckhandTransportException('Serial port is not writable.');
    }
    final writer = writable.callMethodVarArgs<JSObject>('getWriter'.toJS);
    try {
      await writer
          .callMethodVarArgs<JSPromise<JSAny?>>('write'.toJS, [bytes.toJS])
          .toDart;
    } finally {
      writer.callMethodVarArgs<JSAny?>('releaseLock'.toJS);
    }
  }

  @override
  Future<void> openUsb({required Map<String, Object?> filters}) async {
    final usb = _navigatorCapability('usb', 'WebUSB');
    final device = await usb
        .callMethodVarArgs<JSPromise<JSObject>>('requestDevice'.toJS, [
          _requestOptions(filters),
        ])
        .toDart;
    await device.callMethodVarArgs<JSPromise<JSAny?>>('open'.toJS).toDart;
    final configuration = _intValue(filters['configuration_value']);
    if (configuration != null) {
      await device
          .callMethodVarArgs<JSPromise<JSAny?>>('selectConfiguration'.toJS, [
            configuration.toJS,
          ])
          .toDart;
    } else if (device.getProperty<JSAny?>('configuration'.toJS) == null) {
      await device
          .callMethodVarArgs<JSPromise<JSAny?>>('selectConfiguration'.toJS, [
            1.toJS,
          ])
          .toDart;
    }
    final interfaceNumber = _intValue(filters['interface_number']);
    if (interfaceNumber != null) {
      await device
          .callMethodVarArgs<JSPromise<JSAny?>>('claimInterface'.toJS, [
            interfaceNumber.toJS,
          ])
          .toDart;
    }
    _usbDevice = device;
  }

  @override
  Future<void> usbControlTransferOut({
    required String requestType,
    required String recipient,
    required int request,
    required int value,
    required int index,
    required Uint8List bytes,
  }) async {
    final device = _usbDevice;
    if (device == null) {
      throw const DeckhandTransportException('USB device is not open.');
    }
    await device
        .callMethodVarArgs<JSPromise<JSAny?>>('controlTransferOut'.toJS, [
          {
            'requestType': requestType,
            'recipient': recipient,
            'request': request,
            'value': value,
            'index': index,
          }.jsify(),
          bytes.toJS,
        ])
        .toDart;
  }

  @override
  Future<void> openHid({required Map<String, Object?> filters}) async {
    final hid = _navigatorCapability('hid', 'WebHID');
    final devices = await hid
        .callMethodVarArgs<JSPromise<JSObject>>('requestDevice'.toJS, [
          _requestOptions(filters),
        ])
        .toDart;
    final length = devices.getProperty<JSNumber>('length'.toJS).toDartInt;
    if (length == 0) {
      throw const DeckhandTransportException('No HID device was selected.');
    }
    final device = devices.getProperty<JSObject>('0'.toJS);
    await device.callMethodVarArgs<JSPromise<JSAny?>>('open'.toJS).toDart;
    _hidDevice = device;
  }

  @override
  Future<void> hidSendReport({
    required int reportId,
    required Uint8List bytes,
  }) async {
    final device = _hidDevice;
    if (device == null) {
      throw const DeckhandTransportException('HID device is not open.');
    }
    await device
        .callMethodVarArgs<JSPromise<JSAny?>>('sendReport'.toJS, [
          reportId.toJS,
          bytes.toJS,
        ])
        .toDart;
  }

  @override
  Future<void> close() async {
    await _closeJsDevice(_serialPort);
    await _closeJsDevice(_usbDevice);
    await _closeJsDevice(_hidDevice);
    _serialPort = null;
    _usbDevice = null;
    _hidDevice = null;
  }
}

JSObject _navigatorCapability(String key, String label) {
  final navigator = globalContext.getProperty<JSObject?>('navigator'.toJS);
  final capability = navigator?.getProperty<JSObject?>(key.toJS);
  if (capability == null) {
    throw DeckhandTransportException(
      '$label is not available in this browser.',
    );
  }
  return capability;
}

JSAny? _requestOptions(Map<String, Object?> filters) {
  final rawFilters = filters['filters'];
  final normalizedFilters = rawFilters is List
      ? rawFilters
      : filters.isEmpty
      ? const <Object?>[]
      : [_normalizeDeviceFilter(filters)];
  return {'filters': normalizedFilters}.jsify();
}

Map<String, Object?> _normalizeDeviceFilter(Map<String, Object?> filter) {
  return {
    for (final entry in filter.entries)
      if (!_controlKeys.contains(entry.key))
        _camelDeviceKey(entry.key): entry.value,
  };
}

const _controlKeys = {
  'configuration_value',
  'interface_number',
  'chunk_size',
  'baud_rate',
};

String _camelDeviceKey(String key) {
  switch (key) {
    case 'vendor_id':
      return 'vendorId';
    case 'product_id':
      return 'productId';
    case 'usage_page':
      return 'usagePage';
    case 'usage':
      return 'usage';
    default:
      return key;
  }
}

int? _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value?.toString() ?? '');
}

Future<void> _closeJsDevice(JSObject? device) async {
  if (device == null) {
    return;
  }
  try {
    await device.callMethodVarArgs<JSPromise<JSAny?>>('close'.toJS).toDart;
  } catch (_) {
    // Device was already disconnected or closed by the browser.
  }
}
