import 'dart:html' as html;
import 'dart:js_util' as js_util;

import 'transport_capabilities.dart';

DeckhandTransportAvailability detectDeckhandWebTransports() {
  final navigator = html.window.navigator;
  return DeckhandTransportAvailability(
    webUsb: js_util.hasProperty(navigator, 'usb'),
    webHid: js_util.hasProperty(navigator, 'hid'),
    webSerial: js_util.hasProperty(navigator, 'serial'),
    manualDownload: true,
  );
}
