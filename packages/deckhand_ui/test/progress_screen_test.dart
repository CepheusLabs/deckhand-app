import 'dart:async';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/providers.dart';
import 'package:deckhand_ui/src/screens/progress_screen.dart';
import 'package:deckhand_ui/src/theming/deckhand_theme.dart';
import 'package:deckhand_ui/src/widgets/wizard_progress_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'helpers.dart';

void main() {
  test('progress errors use the shared user-facing formatter', () {
    expect(
      progressRunErrorMessage(
        const HostNotApprovedException(
          host: 'armbian.lv.auroradev.org',
          reason: 'not approved',
        ),
      ),
      'Network access to armbian.lv.auroradev.org was not approved. Retry and choose Allow, or approve it from Settings.',
    );
  });

  group('ProgressScreen', () {
    testWidgets('phase-aware title reads step kind from controller', (
      tester,
    ) async {
      // Minimal profile: one ssh_commands step. The log-only path is
      // enough to exercise the title/ step-kind plumbing.
      final controller = stubWizardController(
        profileJson: testProfileJson(
          stockKeepSteps: [
            {
              'id': 'stop_services',
              'kind': 'ssh_commands',
              'commands': <String>[],
            },
          ],
        ),
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

    testWidgets(
      'fresh flash without an SSH host routes to the first-boot handoff',
      (tester) async {
        final controller = stubWizardController(
          profileJson: testProfileJson(
            freshFlashSteps: [
              {'id': 'wait_for_ssh', 'kind': 'wait_for_ssh'},
            ],
          ),
        );
        await controller.loadProfile('test-printer');
        controller.setFlow(WizardFlow.freshFlash);

        await tester.pumpWidget(_progressHandoffHarness(controller));
        await tester.pumpAndSettle();

        expect(find.text('FIRST BOOT HANDOFF'), findsOneWidget);
        expect(find.text('Run stopped'), findsNothing);
        expect(controller.state.currentStep, 'first-boot');
      },
    );

    testWidgets('prompt step shows an AlertDialog with profile message', (
      tester,
    ) async {
      final controller = stubWizardController(
        // `backup_prompt` specifically is suppressed engine-side
        // (consolidated into S145 snapshot screen). Use a different
        // id so this generic prompt-rendering test still drives the
        // dialog code path.
        profileJson: testProfileJson(
          stockKeepSteps: [
            {
              'id': 'continue_prompt',
              'kind': 'prompt',
              'message': 'Back up before proceeding',
              'actions': [
                {'id': 'back_up', 'label': 'Back up now'},
                {'id': 'skip', 'label': 'Skip'},
              ],
            },
          ],
        ),
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

    testWidgets('prompt step skips malformed action rows', (tester) async {
      final controller = stubWizardController(
        profileJson: testProfileJson(
          stockKeepSteps: [
            {
              'id': 'continue_prompt',
              'kind': 'prompt',
              'message': 'Pick the safe action',
              'actions': [
                'bad row',
                {'id': 42, 'label': 99},
                {'id': 'continue', 'label': 'Continue'},
              ],
            },
          ],
        ),
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

      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.text('Pick the safe action'), findsOneWidget);
      expect(find.text('Continue'), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
    });

    testWidgets('prompt step tolerates malformed optional text fields', (
      tester,
    ) async {
      final controller = stubWizardController(
        profileJson: testProfileJson(
          stockKeepSteps: [
            {
              'id': 'continue_prompt',
              'kind': 'prompt',
              'title': 42,
              'message': ['bad shape'],
              'actions': {'not': 'a list'},
            },
          ],
        ),
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

      expect(find.text('Continue'), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
    });

    testWidgets('prompt step with no actions falls back to a Continue button', (
      tester,
    ) async {
      final controller = stubWizardController(
        profileJson: testProfileJson(
          stockKeepSteps: [
            {'id': 'done_prompt', 'kind': 'prompt', 'message': 'All set'},
          ],
        ),
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
    });

    testWidgets('host approval prompt retries execution', (tester) async {
      final security = _PromptingSecurity();
      final upstream = _HostBlockedUpstream(security);
      final controller = stubWizardController(
        security: security,
        upstream: upstream,
        profileJson: testProfileJson(
          os: {
            'fresh_install_options': [
              {
                'id': 'trixie',
                'display_name': 'Debian',
                'url': 'https://armbian.lv.auroradev.org/image.img',
                'sha256':
                    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                'recommended': true,
              },
            ],
          },
          freshFlashSteps: [
            {'id': 'download_os', 'kind': 'os_download'},
          ],
        ),
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.freshFlash);
      await controller.setDecision('flash.os', 'trixie');

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

      expect(find.text('Allow profile network access?'), findsOneWidget);
      expect(find.textContaining('armbian.lv.auroradev.org'), findsWidgets);
      expect(upstream.attempts, 0);

      await tester.tap(find.text('Allow'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(security.approvedHosts, contains('armbian.lv.auroradev.org'));
      expect(upstream.attempts, 1);
      expect(find.text('All done'), findsOneWidget);
    });

    testWidgets('resumed progress pre-approves profile network hosts', (
      tester,
    ) async {
      final security = _PromptingSecurity();
      final upstream = _HostBlockedUpstream(security);
      final controller = stubWizardController(
        security: security,
        upstream: upstream,
        profileJson: testProfileJson(
          os: {
            'fresh_install_options': [
              {
                'id': 'trixie',
                'display_name': 'Debian',
                'url': 'https://downloads.example.com/image.img',
                'sha256':
                    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                'recommended': true,
              },
            ],
          },
          freshFlashSteps: [
            {'id': 'download_os', 'kind': 'os_download'},
          ],
        ),
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.freshFlash);
      await controller.setDecision('flash.os', 'trixie');

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

      expect(find.text('Allow profile network access?'), findsOneWidget);
      expect(find.textContaining('downloads.example.com'), findsWidgets);
      expect(upstream.attempts, 0);

      await tester.tap(find.text('Allow'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(security.approvedHosts, ['downloads.example.com']);
      expect(upstream.attempts, 1);
      expect(find.text('All done'), findsOneWidget);
    });

    testWidgets('active progress header uses determinate step progress', (
      tester,
    ) async {
      final releaseDownload = Completer<void>();
      final upstream = _HoldingProgressUpstream(releaseDownload);
      final controller = stubWizardController(
        upstream: upstream,
        profileJson: testProfileJson(
          os: {
            'fresh_install_options': [
              {
                'id': 'trixie',
                'display_name': 'Debian',
                'url': 'https://downloads.example.com/image.img',
                'sha256':
                    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                'recommended': true,
              },
            ],
          },
          freshFlashSteps: [
            {'id': 'download_os', 'kind': 'os_download'},
          ],
        ),
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.freshFlash);
      await controller.setDecision('flash.os', 'trixie');

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

      expect(find.text('STEP 1/1 · Prepare OS image'), findsOneWidget);
      expect(find.text('STEP 1/1 · download_os'), findsNothing);
      expect(find.text('50.0%'), findsOneWidget);
      expect(find.textContaining('5.0 MiB / 10.0 MiB'), findsOneWidget);

      final bar = tester.widget<WizardProgressBar>(
        find.byType(WizardProgressBar),
      );
      expect(bar.fraction, 0.5);
      expect(bar.animateStripes, isFalse);

      releaseDownload.complete();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('All done'), findsOneWidget);
    });

    testWidgets('choose_one step tolerates malformed optional text fields', (
      tester,
    ) async {
      final controller = stubWizardController(
        profileJson: testProfileJson(
          stockKeepSteps: [
            {
              'id': 'choice',
              'kind': 'choose_one',
              'title': 42,
              'question': ['bad shape'],
              'options': [
                {
                  'id': 'a',
                  'label': 'Option A',
                  'description': ['bad'],
                },
              ],
            },
          ],
        ),
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

      expect(find.text('Option A'), findsOneWidget);
      expect(find.textContaining('bad shape'), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
    });

    testWidgets('choose_one screens skip malformed descriptions', (
      tester,
    ) async {
      final controller = stubWizardController(
        profileJson: {
          ...testProfileJson(
            stockKeepSteps: [
              {'id': 'screen', 'kind': 'choose_one', 'options_from': 'screens'},
            ],
          ),
          'screens': [
            {
              'id': 'stock',
              'display_name': 'Stock screen',
              'description': ['bad shape'],
            },
          ],
        },
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

      expect(find.text('Stock screen'), findsOneWidget);
      expect(find.textContaining('bad shape'), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
    });

    test('progressRunErrorMessage explains Windows volume lock failures', () {
      final message = progressRunErrorMessage(
        r'StepExecutionException: prepare target: lock volume \\?\Volume{81442efe-49a7-11f1-bd05-4c23380248b8}\ after dismounting busy filesystem: Access is denied.',
      );

      expect(message, contains('Windows would not release the selected disk'));
      expect(message, contains('Close File Explorer'));
      expect(message, isNot(contains('StepExecutionException')));
      expect(message, isNot(contains(r'\\?\Volume')));
    });

    test('progressRunErrorMessage explains helper launch failures', () {
      final message = progressRunErrorMessage(
        r'ElevatedHelperException: elevated helper never started. The UAC prompt may have been suppressed or the elevated process could not be launched.',
      );

      expect(
        message,
        contains('Windows did not start Deckhand\'s disk helper'),
      );
      expect(message, contains('Start Deckhand as Administrator'));
      expect(message, isNot(contains('ElevatedHelperException')));
    });

    test('progressRunErrorMessage explains raw disk access failures', () {
      final message = progressRunErrorMessage(
        r'Exception: ElevatedHelperException: write \\.\PHYSICALDRIVE3: Access is denied.',
      );

      expect(message, contains('Windows denied raw-disk access'));
      expect(message, contains('Windows disk 3'));
      expect(message, isNot(contains('PHYSICALDRIVE3')));
      expect(message, isNot(contains('ElevatedHelperException')));
    });

    test('progressRunErrorMessage hides raw physical drive ids', () {
      final message = progressRunErrorMessage(
        r'StepExecutionException: write: write \\.\PHYSICALDRIVE3: The parameter is incorrect.',
      );

      expect(message, contains('Windows disk 3'));
      expect(message, isNot(contains('PHYSICALDRIVE3')));
    });

    test('progressRunErrorMessage explains Windows volume query failures', () {
      final message = progressRunErrorMessage(
        r'StepExecutionException: prepare target: query volume \\?\Volume{81442efe-49a7-11f1-bd05-4c23380248b8}\ extents: Incorrect function.',
      );

      expect(message, contains('Windows could not inspect'));
      expect(message, contains('Replug the USB adapter'));
      expect(message, isNot(contains(r'\\?\Volume')));
      expect(message, isNot(contains('StepExecutionException')));
    });

    testWidgets('running install can be canceled from progress screen', (
      tester,
    ) async {
      final releaseDownload = Completer<void>();
      final upstream = _HoldingProgressUpstream(releaseDownload);
      final controller = stubWizardController(
        upstream: upstream,
        profileJson: testProfileJson(
          os: {
            'fresh_install_options': [
              {
                'id': 'trixie',
                'display_name': 'Debian',
                'url': 'https://downloads.example.com/image.img',
                'sha256':
                    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                'recommended': true,
              },
            ],
          },
          freshFlashSteps: [
            {'id': 'download_os', 'kind': 'os_download'},
            {'id': 'next_step', 'kind': 'ssh_commands', 'commands': <String>[]},
          ],
        ),
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.freshFlash);
      await controller.setDecision('flash.os', 'trixie');

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

      expect(find.widgetWithText(TextButton, 'Cancel install'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel install'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Cancel install?'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Cancel install'));
      await tester.pump();
      expect(find.text('Cancel requested...'), findsOneWidget);

      releaseDownload.complete();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.text('Install canceled'), findsOneWidget);
      expect(find.text('Run canceled'), findsOneWidget);
      expect(find.text('next_step'), findsNothing);
    });

    testWidgets('extracting without a reported total is indeterminate', (
      tester,
    ) async {
      final releaseDownload = Completer<void>();
      final upstream = _HoldingExtractionUpstream(releaseDownload);
      final controller = stubWizardController(
        upstream: upstream,
        profileJson: testProfileJson(
          os: {
            'fresh_install_options': [
              {
                'id': 'trixie',
                'display_name': 'Debian',
                'url': 'https://downloads.example.com/image.img.xz',
                'sha256':
                    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                'recommended': true,
              },
            ],
          },
          freshFlashSteps: [
            {'id': 'download_os', 'kind': 'os_download'},
          ],
        ),
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.freshFlash);
      await controller.setDecision('flash.os', 'trixie');

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

      expect(find.text('Extracting image'), findsOneWidget);
      expect(find.text('0.0%'), findsNothing);
      expect(find.textContaining('8.0 MiB'), findsOneWidget);

      final bar = tester.widget<WizardProgressBar>(
        find.byType(WizardProgressBar),
      );
      expect(bar.fraction, isNull);
      expect(bar.animateStripes, isFalse);

      releaseDownload.complete();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('All done'), findsOneWidget);
    });

    testWidgets('extracting with a reported total is determinate', (
      tester,
    ) async {
      final releaseDownload = Completer<void>();
      final upstream = _HoldingExtractionUpstream(
        releaseDownload,
        reportedTotalBytes: 10 * 1024 * 1024,
      );
      final controller = stubWizardController(
        upstream: upstream,
        profileJson: testProfileJson(
          os: {
            'fresh_install_options': [
              {
                'id': 'trixie',
                'display_name': 'Debian',
                'url': 'https://downloads.example.com/image.img.xz',
                'sha256':
                    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                'recommended': true,
              },
            ],
          },
          freshFlashSteps: [
            {'id': 'download_os', 'kind': 'os_download'},
          ],
        ),
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.freshFlash);
      await controller.setDecision('flash.os', 'trixie');

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

      expect(find.text('Extracting image'), findsOneWidget);
      expect(find.text('80.0%'), findsOneWidget);
      expect(find.textContaining('8.0 MiB / 10.0 MiB'), findsOneWidget);

      final bar = tester.widget<WizardProgressBar>(
        find.byType(WizardProgressBar),
      );
      expect(bar.fraction, 0.8);

      releaseDownload.complete();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('All done'), findsOneWidget);
    });

    testWidgets('host approval prompt can approve sequential hosts', (
      tester,
    ) async {
      final security = _PromptingSecurity();
      final upstream = _MultiHostBlockedUpstream([
        'api.github.com',
        'github-releases.githubusercontent.com',
      ]);
      final controller = stubWizardController(
        security: security,
        upstream: upstream,
        profileJson: testProfileJson(
          os: {
            'fresh_install_options': [
              {
                'id': 'trixie',
                'display_name': 'Debian',
                'url': 'https://github.com/armbian/community/image.img',
                'sha256':
                    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                'recommended': true,
              },
            ],
          },
          freshFlashSteps: [
            {'id': 'download_os', 'kind': 'os_download'},
          ],
        ),
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.freshFlash);
      await controller.setDecision('flash.os', 'trixie');

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

      expect(find.text('Allow profile network access?'), findsOneWidget);
      expect(find.textContaining('github.com'), findsWidgets);
      await tester.tap(find.text('Allow'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.textContaining('api.github.com'), findsWidgets);
      await tester.tap(find.text('Allow'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(
        find.textContaining('github-releases.githubusercontent.com'),
        findsWidgets,
      );
      await tester.tap(find.text('Allow'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(security.approvedHosts, [
        'github.com',
        'api.github.com',
        'github-releases.githubusercontent.com',
      ]);
      expect(upstream.attempts, 3);
      expect(find.text('All done'), findsOneWidget);
    });

    testWidgets('unknown choose_one options block OK', (tester) async {
      final controller = stubWizardController(
        profileJson: testProfileJson(
          stockKeepSteps: [
            {
              'id': 'bad_choice',
              'kind': 'choose_one',
              'options_from': 'missing.options',
            },
          ],
        ),
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

      expect(find.text('Options unavailable'), findsOneWidget);
      final ok = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'OK'),
      );
      expect(ok.onPressed, isNull);
    });
  });
}

Widget _progressHandoffHarness(WizardController controller) {
  final router = GoRouter(
    initialLocation: '/progress',
    routes: [
      GoRoute(path: '/progress', builder: (_, _) => const ProgressScreen()),
      GoRoute(
        path: '/first-boot',
        builder: (_, _) => const Scaffold(body: Text('FIRST BOOT HANDOFF')),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      ...overrideForController(controller),
      deckhandSettingsProvider.overrideWithValue(
        DeckhandSettings(path: '<memory>'),
      ),
    ],
    child: MaterialApp.router(
      routerConfig: router,
      theme: DeckhandTheme.light(),
      darkTheme: DeckhandTheme.dark(),
    ),
  );
}

class _HoldingProgressUpstream implements UpstreamService {
  _HoldingProgressUpstream(this.releaseDownload);

  final Completer<void> releaseDownload;

  @override
  Stream<OsDownloadProgress> osDownload({
    required String url,
    required String destPath,
    String? expectedSha256,
  }) async* {
    yield OsDownloadProgress(
      bytesDone: 5 * 1024 * 1024,
      bytesTotal: 10 * 1024 * 1024,
      phase: OsDownloadPhase.downloading,
      path: destPath,
    );
    await releaseDownload.future;
    yield OsDownloadProgress(
      bytesDone: 10 * 1024 * 1024,
      bytesTotal: 10 * 1024 * 1024,
      phase: OsDownloadPhase.done,
      sha256: expectedSha256,
      path: destPath,
    );
  }

  @override
  Future<UpstreamFetchResult> gitFetch({
    required String repoUrl,
    required String ref,
    required String destPath,
    int depth = 1,
  }) async => UpstreamFetchResult(localPath: destPath, resolvedRef: ref);

  @override
  Future<UpstreamFetchResult> releaseFetch({
    required String repoSlug,
    required String assetPattern,
    required String destPath,
    required String expectedSha256,
    String? tag,
  }) async =>
      UpstreamFetchResult(localPath: destPath, resolvedRef: tag ?? 'latest');
}

class _HoldingExtractionUpstream implements UpstreamService {
  _HoldingExtractionUpstream(
    this.releaseDownload, {
    this.reportedTotalBytes = 0,
  });

  final Completer<void> releaseDownload;
  final int reportedTotalBytes;

  @override
  Stream<OsDownloadProgress> osDownload({
    required String url,
    required String destPath,
    String? expectedSha256,
  }) async* {
    yield OsDownloadProgress(
      bytesDone: 8 * 1024 * 1024,
      bytesTotal: reportedTotalBytes,
      phase: OsDownloadPhase.extracting,
      path: destPath,
    );
    await releaseDownload.future;
    yield OsDownloadProgress(
      bytesDone: 10 * 1024 * 1024,
      bytesTotal: 10 * 1024 * 1024,
      phase: OsDownloadPhase.done,
      sha256: expectedSha256,
      path: destPath,
    );
  }

  @override
  Future<UpstreamFetchResult> gitFetch({
    required String repoUrl,
    required String ref,
    required String destPath,
    int depth = 1,
  }) async => UpstreamFetchResult(localPath: destPath, resolvedRef: ref);

  @override
  Future<UpstreamFetchResult> releaseFetch({
    required String repoSlug,
    required String assetPattern,
    required String destPath,
    required String expectedSha256,
    String? tag,
  }) async =>
      UpstreamFetchResult(localPath: destPath, resolvedRef: tag ?? 'latest');
}

class _MultiHostBlockedUpstream implements UpstreamService {
  _MultiHostBlockedUpstream(this.hosts);

  final List<String> hosts;
  int attempts = 0;

  @override
  Stream<OsDownloadProgress> osDownload({
    required String url,
    required String destPath,
    String? expectedSha256,
  }) async* {
    attempts++;
    final hostIndex = attempts - 1;
    if (hostIndex < hosts.length) {
      throw HostNotApprovedException(
        host: hosts[hostIndex],
        reason: 'network access to this host has not been approved',
      );
    }
    yield OsDownloadProgress(
      bytesDone: 1,
      bytesTotal: 1,
      phase: OsDownloadPhase.done,
      sha256: expectedSha256,
      path: destPath,
    );
  }

  @override
  Future<UpstreamFetchResult> gitFetch({
    required String repoUrl,
    required String ref,
    required String destPath,
    int depth = 1,
  }) async => UpstreamFetchResult(localPath: destPath, resolvedRef: ref);

  @override
  Future<UpstreamFetchResult> releaseFetch({
    required String repoSlug,
    required String assetPattern,
    required String destPath,
    required String expectedSha256,
    String? tag,
  }) async =>
      UpstreamFetchResult(localPath: destPath, resolvedRef: tag ?? 'latest');
}

class _HostBlockedUpstream implements UpstreamService {
  _HostBlockedUpstream(this.security);

  final SecurityService security;
  int attempts = 0;

  @override
  Stream<OsDownloadProgress> osDownload({
    required String url,
    required String destPath,
    String? expectedSha256,
  }) async* {
    attempts++;
    await requireHostApproved(security, url);
    yield OsDownloadProgress(
      bytesDone: 1,
      bytesTotal: 1,
      phase: OsDownloadPhase.done,
      sha256: expectedSha256,
      path: destPath,
    );
  }

  @override
  Future<UpstreamFetchResult> gitFetch({
    required String repoUrl,
    required String ref,
    required String destPath,
    int depth = 1,
  }) async => UpstreamFetchResult(localPath: destPath, resolvedRef: ref);

  @override
  Future<UpstreamFetchResult> releaseFetch({
    required String repoSlug,
    required String assetPattern,
    required String destPath,
    required String expectedSha256,
    String? tag,
  }) async =>
      UpstreamFetchResult(localPath: destPath, resolvedRef: tag ?? 'latest');
}

class _PromptingSecurity implements SecurityService {
  final approvedHosts = <String>[];

  @override
  Future<void> approveHost(String host) async => approvedHosts.add(host);

  @override
  Future<bool> isHostAllowed(String host) async => approvedHosts.contains(host);

  @override
  Future<ConfirmationToken> issueConfirmationToken({
    required String operation,
    required String target,
    Duration ttl = const Duration(seconds: 60),
  }) async => ConfirmationToken(
    value: 'test-token-0123456789abcdef',
    expiresAt: DateTime.now().add(ttl),
    operation: operation,
    target: target,
  );

  @override
  bool consumeToken(String value, String operation, {required String target}) =>
      true;

  @override
  Future<Map<String, bool>> requestHostApprovals(List<String> hosts) async => {
    for (final host in hosts) host: approvedHosts.contains(host),
  };

  @override
  Future<void> revokeHost(String host) async => approvedHosts.remove(host);

  @override
  Future<List<String>> listApprovedHosts() async => approvedHosts.toList();

  @override
  Future<void> pinHostFingerprint({
    required String host,
    required String fingerprint,
  }) async {}

  @override
  Future<String?> pinnedHostFingerprint(String host) async => null;

  @override
  Future<void> forgetHostFingerprint(String host) async {}

  @override
  Future<Map<String, String>> listPinnedFingerprints() async => const {};

  @override
  Future<String?> getGitHubToken() async => null;

  @override
  Future<void> setGitHubToken(String? token) async {}

  @override
  Stream<EgressEvent> get egressEvents => const Stream.empty();

  @override
  void recordEgress(EgressEvent event) {}
}
