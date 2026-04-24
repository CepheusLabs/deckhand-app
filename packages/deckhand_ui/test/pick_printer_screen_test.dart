import 'package:deckhand_ui/src/screens/pick_printer_screen.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('PickPrinterScreen', () {
    testWidgets('renders without crashing', (tester) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const PickPrinterScreen(),
          initialLocation: '/pick-printer',
        ),
      );
      // The screen fetches the registry asynchronously; pump a few
      // frames instead of pumpAndSettle (which would block on the
      // stub's `never completes` futures).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Whatever state the screen lands in (loading, empty list,
      // error), the U+2192 right-arrow glyph must NOT appear. That
      // was a Phase 8 correctness fix; this test keeps it enforced.
      expect(find.textContaining('\u2192'), findsNothing);
    });
  });
}
