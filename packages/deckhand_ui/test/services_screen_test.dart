import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/screens/services_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('ServicesScreen', () {
    testWidgets(
      'walks one wizard question at a time, filtering wizard:none entries',
      (tester) async {
        final controller = stubWizardController(
          profileJson: {
            ...testProfileJson(),
            'stock_os': {
              'services': [
                {
                  'id': 'phrozen_master',
                  'display_name': 'Phrozen master',
                  'default_action': 'disable',
                  'wizard': {'explainer': 'Vendor relay'},
                },
                {
                  'id': 'frpc',
                  'display_name': 'FRP reverse tunnel',
                  'default_action': 'remove',
                  'wizard': {'explainer': 'Phone-home tunnel'},
                },
                {
                  'id': 'internal',
                  'display_name': 'Internal - no wizard',
                  'default_action': 'keep',
                  'wizard': 'none',
                },
              ],
            },
          },
        );
        await controller.loadProfile('test-printer');
        controller.setFlow(WizardFlow.stockKeep);
        await tester.pumpWidget(
          testHarness(
            controller: controller,
            child: const ServicesScreen(),
            initialLocation: '/services',
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // First question is "Phrozen master"; appears in both the
        // screen-head title ("What should we do with…") and the
        // explainer panel header.
        expect(find.textContaining('Phrozen master'), findsWidgets);
        // The second wizard service hasn't surfaced yet (single-
        // question UX) and the wizard:none entry is filtered.
        expect(find.textContaining('FRP reverse tunnel'), findsNothing);
        expect(find.textContaining('Internal - no wizard'), findsNothing);
        // Progress label is visible (only 2 wizard-blocked services).
        expect(find.text('Question 1 / 2'), findsOneWidget);

        // Continue advances to the second question.
        await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
        await tester.pump();

        expect(find.textContaining('Phrozen master'), findsNothing);
        expect(find.textContaining('FRP reverse tunnel'), findsWidgets);
        expect(find.text('Question 2 / 2'), findsOneWidget);
      },
    );

    testWidgets('seeds default decisions on first render (initState path)', (
      tester,
    ) async {
      final controller = stubWizardController(
        profileJson: {
          ...testProfileJson(),
          'stock_os': {
            'services': [
              {
                'id': 'frpc',
                'display_name': 'FRP tunnel',
                'default_action': 'remove',
                'wizard': {'explainer': 'Remove vendor tunnel'},
              },
            ],
          },
        },
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const ServicesScreen(),
          initialLocation: '/services',
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(controller.decision<String>('service.frpc'), 'remove');
    });

    testWidgets('skips malformed wizard options', (tester) async {
      final controller = stubWizardController(
        profileJson: {
          ...testProfileJson(),
          'stock_os': {
            'services': [
              {
                'id': 'frpc',
                'display_name': 'FRP tunnel',
                'default_action': 'remove',
                'wizard': {
                  'question': 'What should happen to FRP?',
                  'options': [
                    'bad row',
                    {'id': 42, 'label': 99},
                    {
                      'id': 'remove',
                      'label': 'Remove it',
                      'description': 'Stop the tunnel service.',
                    },
                  ],
                },
              },
            ],
          },
        },
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const ServicesScreen(),
          initialLocation: '/services',
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Remove it'), findsOneWidget);
      expect(find.text('Stop the tunnel service.'), findsOneWidget);
      expect(find.textContaining('42'), findsNothing);
    });

    testWidgets(
      'Back action renders via t.common.action_back (no hardcoded string)',
      (tester) async {
        final controller = stubWizardController(profileJson: testProfileJson());
        await controller.loadProfile('test-printer');
        controller.setFlow(WizardFlow.stockKeep);
        await tester.pumpWidget(
          testHarness(
            controller: controller,
            child: const ServicesScreen(),
            initialLocation: '/services',
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // Default english translation is "Back" — assertion checks the
        // scaffold renders the action, not a literal child of the
        // screen body.
        expect(find.text('Back'), findsOneWidget);
        expect(find.text('Continue'), findsOneWidget);
      },
    );
  });
}
