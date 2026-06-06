import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'transport_capabilities.dart';

DeckhandTransportAvailability detectDeckhandWebTransports() {
  final navigator = globalContext.getProperty<JSObject?>('navigator'.toJS);
  if (navigator == null) {
    return const DeckhandTransportAvailability(manualDownload: true);
  }
  return DeckhandTransportAvailability(
    webUsb: navigator.has('usb'),
    webHid: navigator.has('hid'),
    webSerial: navigator.has('serial'),
    manualDownload: true,
  );
}
