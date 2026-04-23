import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/screens/progress_screen.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('ProgressScreen', () {
    testWidgets('phase-aware title reads step kind from controller',
        (tester) async {
      // Minimal profile: one ssh_commands step. The log-only path is
      // enough to exercise the title/ step-kind plumbing.
      final controller = stubWizardController(
        profileJson: testProfileJson(stockKeepSteps: [
          {
            'id': 'stop_services',
            'kind': 'ssh_commands',
            'commands': <String>[],
          },
        ]),
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);
      await controller.connectSsh(host: '127.0.0.1');

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const ProgressScreen(),
          initialLocation: '/progress',
        ),
      );
      // First frame: startExecution queues up; title is still the
      // generic default because nothing has started yet.
      await tester.pump();
      // Drive the controller's event stream. pumpAndSettle in test
      // shells with async ops completes the whole run.
      await tester.pumpAndSettle();
      // After execution completes, the title is "All done".
      expect(find.text('All done'), findsOneWidget);
    });

    testWidgets('prompt step shows an AlertDialog with profile message',
        (tester) async {
      final controller = stubWizardController(
        profileJson: testProfileJson(stockKeepSteps: [
          {
            'id': 'backup_prompt',
            'kind': 'prompt',
            'message': 'Back up before proceeding',
            'actions': [
              {'id': 'back_up', 'label': 'Back up now'},
              {'id': 'skip', 'label': 'Skip'},
            ],
          },
        ]),
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);
      await controller.connectSsh(host: '127.0.0.1');
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const ProgressScreen(),
          initialLocation: '/progress',
        ),
      );
      // Pump a few frames so startExecution dispatches the prompt
      // dialog. We can't pumpAndSettle because the dialog is modal
      // and blocks the Future.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Back up before proceeding'), findsOneWidget);
      expect(find.text('Back up now'), findsOneWidget);
      expect(find.text('Skip'), findsOneWidget);

      // Dismiss the dialog so the test's async pump completes.
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
    });

    testWidgets(
      'prompt step with no actions falls back to a Continue button',
      (tester) async {
        final controller = stubWizardController(
          profileJson: testProfileJson(stockKeepSteps: [
            {
              'id': 'done_prompt',
              'kind': 'prompt',
              'message': 'All set',
            },
          ]),
        );
        await controller.loadProfile('test-printer');
        controller.setFlow(WizardFlow.stockKeep);
        await tester.pumpWidget(
          testHarness(
            controller: controller,
            child: const ProgressScreen(),
            initialLocation: '/progress',
          ),
        );
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(find.text('All set'), findsOneWidget);
        expect(find.text('Continue'), findsOneWidget);
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();
      },
    );
  });
}
