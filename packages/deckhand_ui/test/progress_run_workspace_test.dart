import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/widgets/deckhand_loading.dart';
import 'package:deckhand_ui/src/widgets/progress_run_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  testWidgets('active step uses Deckhand spinner', (tester) async {
    final controller = stubWizardController(profileJson: testProfileJson());
    await controller.loadProfile('test-printer');
    await tester.pumpWidget(
      testHarness(
        controller: controller,
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: 1200,
              height: 520,
              child: ProgressRunWorkspace(
                steps: const [
                  RunStep(id: 'download_os', kind: 'os_download'),
                  RunStep(id: 'flash_disk', kind: 'flash_disk'),
                ],
                statusFor: (step) => step.id == 'download_os'
                    ? RunStepStatus.active
                    : RunStepStatus.queued,
                log: const [],
                networkEvents: const [],
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(DeckhandSpinner), findsOneWidget);
  });

  testWidgets('network tab renders captured egress events', (tester) async {
    final controller = stubWizardController(profileJson: testProfileJson());
    await controller.loadProfile('test-printer');
    final startedAt = DateTime.utc(2026, 5, 6, 12);

    await tester.pumpWidget(
      testHarness(
        controller: controller,
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: 1200,
              height: 520,
              child: ProgressRunWorkspace(
                steps: const [RunStep(id: 'download_os', kind: 'os_download')],
                statusFor: (_) => RunStepStatus.done,
                log: const ['[os] ready'],
                networkEvents: [
                  EgressEvent(
                    requestId: 'req-1',
                    host: 'example.com',
                    url: 'https://example.com/image.img',
                    method: 'GET',
                    operationLabel: 'OS image download',
                    startedAt: startedAt,
                    completedAt: startedAt.add(const Duration(seconds: 2)),
                    bytes: 1024,
                    status: 200,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Network'));
    await tester.pumpAndSettle();

    expect(find.text('example.com'), findsOneWidget);
    expect(find.textContaining('OS image download'), findsOneWidget);
    expect(find.textContaining('1.0 KiB'), findsOneWidget);
  });

  testWidgets('log pane defaults to readable text', (tester) async {
    final controller = stubWizardController(profileJson: testProfileJson());
    await controller.loadProfile('test-printer');

    await tester.pumpWidget(
      testHarness(
        controller: controller,
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: 1200,
              height: 520,
              child: ProgressRunWorkspace(
                steps: const [
                  RunStep(id: 'choose_target_disk', kind: 'disk_picker'),
                ],
                statusFor: (_) => RunStepStatus.done,
                log: const ['> starting choose_target_disk'],
                networkEvents: const [],
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.textContaining('Check the selected disk'), findsOneWidget);
    expect(find.textContaining('starting choose_target_disk'), findsNothing);
  });

  testWidgets('log pane uses raw text when developer mode is enabled', (
    tester,
  ) async {
    final controller = stubWizardController(profileJson: testProfileJson());
    await controller.loadProfile('test-printer');

    await tester.pumpWidget(
      testHarnessWithSettings(
        controller: controller,
        settingsSeed: (settings) => settings.developerMode = true,
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: 1200,
              height: 520,
              child: ProgressRunWorkspace(
                steps: const [
                  RunStep(id: 'choose_target_disk', kind: 'disk_picker'),
                ],
                statusFor: (_) => RunStepStatus.done,
                log: const ['> starting choose_target_disk'],
                networkEvents: const [],
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.textContaining('starting choose_target_disk'), findsOneWidget);
    expect(find.textContaining('Check the selected disk'), findsNothing);
  });

  testWidgets('copy log writes visible rows with line breaks', (tester) async {
    final controller = stubWizardController(profileJson: testProfileJson());
    await controller.loadProfile('test-printer');
    var clipboardText = '';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          final data = Map<String, dynamic>.from(call.arguments as Map);
          clipboardText = data['text'] as String? ?? '';
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      testHarness(
        controller: controller,
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: 1200,
              height: 520,
              child: ProgressRunWorkspace(
                steps: const [
                  RunStep(id: 'choose_target_disk', kind: 'disk_picker'),
                ],
                statusFor: (_) => RunStepStatus.done,
                log: const [
                  '> starting choose_target_disk',
                  '[ok] choose_target_disk',
                ],
                networkEvents: const [],
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Copy log'));
    await tester.pumpAndSettle();

    expect(clipboardText, contains('00:00.000\tSTEP\tCheck the selected disk'));
    expect(
      clipboardText,
      contains('\n00:01.017\tOK\tFinished Check the selected disk'),
    );
  });
}
