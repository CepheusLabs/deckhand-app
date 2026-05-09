import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/screens/screen_choice_screen.dart';
import 'package:deckhand_ui/src/widgets/status_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('ScreenChoiceScreen', () {
    testWidgets('renders every screen option with its status badge', (
      tester,
    ) async {
      final controller = stubWizardController(
        profileJson: {
          ...testProfileJson(),
          'screens': [
            {
              'id': 'klipperscreen',
              'display_name': 'KlipperScreen',
              'status': 'stable',
              'recommended': true,
            },
            {
              'id': 'open_arco_screen',
              'display_name': 'Open Arco Screen',
              'status': 'alpha',
            },
            {
              'id': 'none',
              'display_name': 'No touchscreen',
              'status': 'stable',
            },
          ],
        },
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const ScreenChoiceScreen(),
          initialLocation: '/screen-choice',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('KlipperScreen'), findsOneWidget);
      expect(find.text('Open Arco Screen'), findsOneWidget);
      expect(find.text('No touchscreen'), findsOneWidget);

      // Status pills render via the shared StatusPill widget. Pills
      // visually uppercase the label per the design spec — search for
      // the rendered (uppercase) form.
      expect(find.byType(StatusPill), findsWidgets);
      expect(find.text('ALPHA'), findsOneWidget);
      expect(find.text('STABLE'), findsWidgets);
    });

    testWidgets(
      '"source: <kind>" developer string does NOT leak when notes are empty',
      (tester) async {
        final controller = stubWizardController(
          profileJson: {
            ...testProfileJson(),
            'screens': [
              {
                'id': 'klipperscreen',
                'display_name': 'KlipperScreen',
                'source_kind': 'git',
                // no notes
              },
            ],
          },
        );
        await controller.loadProfile('test-printer');
        controller.setFlow(WizardFlow.stockKeep);
        await tester.pumpWidget(
          testHarness(
            controller: controller,
            child: const ScreenChoiceScreen(),
            initialLocation: '/screen-choice',
          ),
        );
        await tester.pumpAndSettle();

        // The old behaviour leaked "source: git" as the subtitle. The
        // current code suppresses that entirely.
        expect(find.textContaining('source:'), findsNothing);
        expect(find.text('git'), findsNothing);
      },
    );

    testWidgets('does not auto-select alpha-only screen options', (
      tester,
    ) async {
      final controller = stubWizardController(
        profileJson: {
          ...testProfileJson(),
          'screens': [
            {
              'id': 'open_arco_screen',
              'display_name': 'Open Arco Screen',
              'status': 'alpha',
            },
            {
              'id': 'experimental_screen',
              'display_name': 'Experimental Screen',
              'status': 'experimental',
            },
          ],
        },
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const ScreenChoiceScreen(),
          initialLocation: '/screen-choice',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Open Arco Screen'), findsOneWidget);
      expect(find.text('Experimental Screen'), findsOneWidget);
      expect(controller.state.decisions['screen'], isNull);
      final continueButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Continue'),
      );
      expect(continueButton.onPressed, isNull);
    });
  });
}
