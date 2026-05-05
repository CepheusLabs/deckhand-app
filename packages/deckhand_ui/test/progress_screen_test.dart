import 'dart:async';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/screens/progress_screen.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
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
      final upstream = _HostBlockedUpstream();
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

      expect(find.text('Allow network access?'), findsOneWidget);
      expect(find.textContaining('armbian.lv.auroradev.org'), findsWidgets);
      expect(upstream.attempts, 1);

      await tester.tap(find.text('Allow'));
      await tester.pumpAndSettle();

      expect(security.approvedHosts, contains('armbian.lv.auroradev.org'));
      expect(upstream.attempts, 2);
      expect(find.text('All done'), findsOneWidget);
    });
  });
}

class _HostBlockedUpstream implements UpstreamService {
  int attempts = 0;

  @override
  Stream<OsDownloadProgress> osDownload({
    required String url,
    required String destPath,
    String? expectedSha256,
  }) async* {
    attempts++;
    if (attempts == 1) {
      throw const HostNotApprovedException(
        host: 'armbian.lv.auroradev.org',
        reason: 'host is not on the user-approved allowlist',
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
  );

  @override
  bool consumeToken(String value, String operation) => true;

  @override
  Future<Map<String, bool>> requestHostApprovals(List<String> hosts) async => {
    for (final host in hosts) host: true,
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
