import 'package:deckhand_ui/src/screens/snapshot_screen.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('SnapshotScreen', () {
    testWidgets('renders the no-paths copy when the profile declares none',
        (tester) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const SnapshotScreen(),
          initialLocation: '/snapshot',
        ),
      );
      await tester.pumpAndSettle();

      // Heading is rendered.
      expect(find.textContaining('Save your current configuration'),
          findsWidgets);
      // The "no paths declared" message reaches the user.
      expect(
        find.textContaining("doesn't declare any snapshot paths"),
        findsOneWidget,
      );
      // Restore strategy radio still appears so the user can pick a
      // default for any future profile that does declare paths.
      expect(find.text('Save as a separate backup'), findsOneWidget);
    });

    testWidgets('renders profile-declared paths with their helper text',
        (tester) async {
      final controller = stubWizardController(
        profileJson: {
          ...testProfileJson(),
          'stock_os': {
            'snapshot_paths': [
              {
                'id': 'config',
                'display_name': 'Printer config',
                'path': '~/printer_data/config',
                'default_selected': true,
                'helper_text': 'printer.cfg + macros',
              },
            ],
          },
        },
      );
      await controller.loadProfile('test-printer');
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const SnapshotScreen(),
          initialLocation: '/snapshot',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Printer config'), findsOneWidget);
      expect(find.text('printer.cfg + macros'), findsOneWidget);
      expect(find.textContaining('~/printer_data/config'), findsOneWidget);
    });
  });
}
