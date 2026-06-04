import 'dart:html' as html;
import 'dart:js_util' as js_util;
import 'dart:typed_data';

import 'package:deckhand_core/deckhand_web_core.dart';

class DeckhandBrowserDeviceTransport implements BrowserDeviceTransport {
  Object? _serialPort;
  Object? _usbDevice;
  Object? _hidDevice;

  @override
  Future<void> openSerial({
    required Map<String, Object?> filters,
    required int baudRate,
  }) async {
    final serial = _navigatorCapability('serial', 'WebSerial');
    final port = await js_util.promiseToFuture<Object>(
      js_util.callMethod(serial, 'requestPort', [_requestOptions(filters)]),
    );
    await js_util.promiseToFuture<void>(
      js_util.callMethod(port, 'open', [
        js_util.jsify({'baudRate': baudRate}),
      ]),
    );
    _serialPort = port;
  }

  @override
  Future<void> writeSerial(Uint8List bytes) async {
    final port = _serialPort;
    if (port == null) {
      throw const DeckhandTransportException('Serial port is not open.');
    }
    final writable = js_util.getProperty<Object?>(port, 'writable');
    if (writable == null) {
      throw const DeckhandTransportException('Serial port is not writable.');
    }
    final writer = js_util.callMethod<Object>(writable, 'getWriter', const []);
    try {
      await js_util.promiseToFuture<void>(
        js_util.callMethod(writer, 'write', [bytes]),
      );
    } finally {
      js_util.callMethod<void>(writer, 'releaseLock', const []);
    }
  }

  @override
  Future<void> openUsb({required Map<String, Object?> filters}) async {
    final usb = _navigatorCapability('usb', 'WebUSB');
    final device = await js_util.promiseToFuture<Object>(
      js_util.callMethod(usb, 'requestDevice', [_requestOptions(filters)]),
    );
    await js_util.promiseToFuture<void>(
      js_util.callMethod(device, 'open', const []),
    );
    final configuration = _intValue(filters['configuration_value']);
    if (configuration != null) {
      await js_util.promiseToFuture<void>(
        js_util.callMethod(device, 'selectConfiguration', [configuration]),
      );
    } else if (js_util.getProperty<Object?>(device, 'configuration') == null) {
      await js_util.promiseToFuture<void>(
        js_util.callMethod(device, 'selectConfiguration', [1]),
      );
    }
    final interfaceNumber = _intValue(filters['interface_number']);
    if (interfaceNumber != null) {
      await js_util.promiseToFuture<void>(
        js_util.callMethod(device, 'claimInterface', [interfaceNumber]),
      );
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
    await js_util.promiseToFuture<Object?>(
      js_util.callMethod(device, 'controlTransferOut', [
        js_util.jsify({
          'requestType': requestType,
          'recipient': recipient,
          'request': request,
          'value': value,
          'index': index,
        }),
        bytes,
      ]),
    );
  }

  @override
  Future<void> openHid({required Map<String, Object?> filters}) async {
    final hid = _navigatorCapability('hid', 'WebHID');
    final devices = await js_util.promiseToFuture<Object>(
      js_util.callMethod(hid, 'requestDevice', [_requestOptions(filters)]),
    );
    final length = js_util.getProperty<int>(devices, 'length');
    if (length == 0) {
      throw const DeckhandTransportException('No HID device was selected.');
    }
    final device = js_util.getProperty<Object>(devices, '0');
    await js_util.promiseToFuture<void>(
      js_util.callMethod(device, 'open', const []),
    );
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
    await js_util.promiseToFuture<void>(
      js_util.callMethod(device, 'sendReport', [reportId, bytes]),
    );
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

Object _navigatorCapability(String key, String label) {
  final capability = js_util.getProperty<Object?>(html.window.navigator, key);
  if (capability == null) {
    throw DeckhandTransportException(
      '$label is not available in this browser.',
    );
  }
  return capability;
}

Object _requestOptions(Map<String, Object?> filters) {
  final rawFilters = filters['filters'];
  final normalizedFilters = rawFilters is List
      ? rawFilters
      : filters.isEmpty
      ? const <Object?>[]
      : [_normalizeDeviceFilter(filters)];
  return js_util.jsify({'filters': normalizedFilters});
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

Future<void> _closeJsDevice(Object? device) async {
  if (device == null) {
    return;
  }
  try {
    await js_util.promiseToFuture<void>(
      js_util.callMethod(device, 'close', const []),
    );
  } catch (_) {
    // Device was already disconnected or closed by the browser.
  }
}
