import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/screens/webui_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('WebuiScreen', () {
    Future<void> pump(
      WidgetTester tester, {
      required List<Object?> choices,
      List<Object?> defaults = const [],
    }) async {
      final controller = stubWizardController(
        profileJson: testProfileJson(
          stack: {
            'webui': {
              'choices': choices,
              'default_choices': defaults,
              'allow_multiple': true,
              'allow_none': false,
            },
          },
        ),
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const WebuiScreen(),
          initialLocation: '/webui',
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('Continue is disabled when nothing is selected', (
      tester,
    ) async {
      await pump(
        tester,
        choices: [
          {'id': 'fluidd', 'display_name': 'Fluidd', 'default_port': 8808},
          {'id': 'mainsail', 'display_name': 'Mainsail', 'default_port': 81},
        ],
        defaults: const [],
      );
      final continueBtn = find.widgetWithText(FilledButton, 'Continue');
      expect(continueBtn, findsOneWidget);
      final btn = tester.widget<FilledButton>(continueBtn);
      expect(btn.onPressed, isNull);
      // Error banner present when empty.
      expect(
        find.textContaining('Pick at least one to continue'),
        findsOneWidget,
      );
    });

    testWidgets('seeded default enables Continue', (tester) async {
      await pump(
        tester,
        choices: [
          {'id': 'fluidd', 'display_name': 'Fluidd', 'default_port': 8808},
          {'id': 'mainsail', 'display_name': 'Mainsail', 'default_port': 81},
        ],
        defaults: const ['fluidd'],
      );
      final continueBtn = find.widgetWithText(FilledButton, 'Continue');
      final btn = tester.widget<FilledButton>(continueBtn);
      expect(btn.onPressed, isNotNull);
    });

    testWidgets('profile description renders, not release_repo', (
      tester,
    ) async {
      await pump(
        tester,
        choices: [
          {
            'id': 'fluidd',
            'display_name': 'Fluidd',
            'description': 'Compact single-page Klipper dashboard.',
            'release_repo': 'fluidd-core/fluidd',
            'default_port': 8808,
          },
        ],
        defaults: const ['fluidd'],
      );
      expect(
        find.textContaining('Compact single-page Klipper dashboard'),
        findsOneWidget,
      );
      // Developer slug should NOT be visible.
      expect(find.textContaining('fluidd-core/fluidd'), findsNothing);
    });

    testWidgets('missing description falls back to "<name> on port <n>"', (
      tester,
    ) async {
      await pump(
        tester,
        choices: [
          {'id': 'custom', 'display_name': 'Custom UI', 'default_port': 9000},
        ],
        defaults: const ['custom'],
      );
      expect(find.text('Custom UI on port 9000'), findsOneWidget);
    });

    testWidgets('malformed choice rows are skipped', (tester) async {
      await pump(
        tester,
        choices: [
          'bad row',
          {'id': 42, 'display_name': 99},
          {'id': 'fluidd', 'display_name': 'Fluidd', 'default_port': 8808},
        ],
        defaults: const [42, 'fluidd'],
      );

      expect(find.text('Fluidd'), findsOneWidget);
      final continueBtn = find.widgetWithText(FilledButton, 'Continue');
      final btn = tester.widget<FilledButton>(continueBtn);
      expect(btn.onPressed, isNotNull);
    });
  });
}
