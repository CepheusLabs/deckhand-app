import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/screens/kiauh_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('KiauhScreen', () {
    testWidgets(
      'renders the profile-authored explainer text for the KIAUH section',
      (tester) async {
        final controller = stubWizardController(
          profileJson: {
            ...testProfileJson(),
            'stack': {
              'kiauh': {
                'wizard': {
                  'explainer':
                      'KIAUH lets you add or remove pieces of the stack later.',
                },
                'default_install': true,
              },
            },
          },
        );
        await controller.loadProfile('test-printer');
        controller.setFlow(WizardFlow.stockKeep);
        await tester.pumpWidget(
          testHarness(
            controller: controller,
            child: const KiauhScreen(),
            initialLocation: '/kiauh',
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.textContaining('KIAUH lets you add or remove'),
          findsOneWidget,
        );
      },
    );

    testWidgets('Continue records kiauh decision on the controller', (
      tester,
    ) async {
      final controller = stubWizardController(
        profileJson: {
          ...testProfileJson(),
          'stack': {
            'kiauh': {'default_install': true},
          },
        },
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const KiauhScreen(),
          initialLocation: '/kiauh',
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
      await tester.pumpAndSettle();

      // default_install=true -> decision should be true.
      expect(controller.decision<bool>('kiauh'), isTrue);
    });

    testWidgets('malformed wizard metadata falls back without crashing', (
      tester,
    ) async {
      final controller = stubWizardController(
        profileJson: {
          ...testProfileJson(),
          'stack': {
            'kiauh': {
              'wizard': ['not a map'],
              'default_install': 'yes',
            },
          },
        },
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const KiauhScreen(),
          initialLocation: '/kiauh',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Install KIAUH'), findsOneWidget);
      final continueButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Continue'),
      );
      expect(continueButton.onPressed, isNotNull);
    });
  });
}
