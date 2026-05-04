import 'package:deckhand_ui/src/screens/hardening_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('HardeningScreen', () {
    testWidgets('renders both toggles and the Continue/Back actions',
        (tester) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const HardeningScreen(),
          initialLocation: '/hardening',
        ),
      );
      await tester.pumpAndSettle();

      // Both checkbox rows render; password fields are hidden by
      // default because change_password defaults to false. The
      // rebuild swapped SwitchListTile for the design's checkbox
      // rows — test pinned the implementation type, not behaviour;
      // updating to match the new component.
      expect(find.byType(Checkbox), findsNWidgets(2));
      expect(find.byType(TextField), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Continue'), findsOneWidget);
    });

    testWidgets('Continue records hardening decisions on the controller',
        (tester) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const HardeningScreen(),
          initialLocation: '/hardening',
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
      await tester.pumpAndSettle();

      // Both hardening toggles default to false; assert they round-trip.
      expect(controller.decision<bool>('hardening.fix_timesync'), isFalse);
      expect(controller.decision<bool>('hardening.change_password'), isFalse);
    });
  });
}
