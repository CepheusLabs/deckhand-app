import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('transport detector has a safe non-web fallback', () {
    final availability = detectDeckhandWebTransports();

    expect(availability.webUsb, isFalse);
    expect(availability.webHid, isFalse);
    expect(availability.webSerial, isFalse);
    expect(availability.manualDownload, isTrue);
    expect(availability.localAgent, isFalse);
    expect(availability.desktopApp, isFalse);
  });
}
