import 'package:deckhand_ui/src/screens/done_screen.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('DoneScreen', () {
    testWidgets('shows printer display_name, not the internal profile_id',
        (tester) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const DoneScreen(),
          initialLocation: '/done',
        ),
      );
      await tester.pumpAndSettle();

      // Profile's display_name = "Test Printer".
      expect(find.text('Test Printer'), findsOneWidget);
      // The internal profile_id should NOT be user-visible.
      expect(find.text('test-printer'), findsNothing);
    });

    testWidgets(
        'webui tip only lists choices the user actually selected',
        (tester) async {
      final controller = stubWizardController(
        profileJson: {
          ...testProfileJson(),
          'stack': {
            'webui': {
              'choices': [
                {
                  'id': 'fluidd',
                  'display_name': 'Fluidd',
                  'default_port': 8808,
                },
                {
                  'id': 'mainsail',
                  'display_name': 'Mainsail',
                  'default_port': 81,
                },
              ],
            },
          },
        },
      );
      await controller.loadProfile('test-printer');
      // User picks Fluidd only; Mainsail should NOT appear in tips.
      await controller.setDecision('webui', ['fluidd']);

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const DoneScreen(),
          initialLocation: '/done',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Fluidd'), findsOneWidget);
      expect(find.textContaining('Mainsail'), findsNothing);
    });

    testWidgets('no kiauh.sh command leaks into user-facing copy',
        (tester) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const DoneScreen(),
          initialLocation: '/done',
        ),
      );
      await tester.pumpAndSettle();

      // Raw shell command must not appear in user copy.
      expect(find.textContaining('kiauh.sh'), findsNothing);
      expect(find.textContaining('./kiauh'), findsNothing);
    });
  });
}
