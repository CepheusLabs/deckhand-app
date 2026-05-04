import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// End-to-end tests for [WizardController] step execution. We stub every
/// service so the controller runs in-process without hitting the
/// filesystem, network, or SSH.
void main() {
  const validImageSha =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  Map<String, dynamic> baseProfileJson({
    List<Map<String, dynamic>>? stockKeepSteps,
    List<Map<String, dynamic>>? freshFlashSteps,
  }) => {
    'profile_id': 'test-printer',
    'profile_version': '0.1.0',
    'display_name': 'Test Printer',
    'status': 'alpha',
    'manufacturer': 'Acme',
    'model': 'Robo',
    'os': {
      'fresh_install_options': [
        {
          'id': 'debian-bookworm',
          'display_name': 'Debian 12',
          'url': 'https://example.com/debian-bookworm.img',
          'sha256': validImageSha,
          'size_bytes_approx': 2000000000,
          'recommended': true,
        },
      ],
    },
    'ssh': {
      'default_port': 22,
      'default_credentials': [
        {'user': 'root', 'password': 'root'},
      ],
    },
    'flows': {
      'stock_keep': {'enabled': true, 'steps': stockKeepSteps ?? const []},
      'fresh_flash': {'enabled': true, 'steps': freshFlashSteps ?? const []},
    },
  };

  WizardController newController({
    required Map<String, dynamic> profileJson,
    FakeSsh? ssh,
    FakeUpstream? upstream,
    _StubFlashService? flash,
    FakeElevatedHelper? helper,
    FakeSecurity? security,
  }) {
    final profile = PrinterProfile.fromJson(profileJson);
    return WizardController(
      profiles: _StubProfileService(profile),
      ssh: ssh ?? FakeSsh(),
      flash: flash ?? _StubFlashService(),
      discovery: _StubDiscoveryService(),
      moonraker: _StubMoonrakerService(),
      upstream: upstream ?? FakeUpstream(),
      security: security ?? FakeSecurity(),
      elevatedHelper: helper,
    );
  }

  group('WizardController._resolveOrAwaitInput', () {
    test(
      'auto-resolves choose_one(os.fresh_install_options) from flash.os decision',
      () async {
        final upstream = FakeUpstream();
        final controller = newController(
          profileJson: baseProfileJson(
            freshFlashSteps: [
              {
                'id': 'choose_os_image',
                'kind': 'choose_one',
                'options_from': 'os.fresh_install_options',
              },
            ],
          ),
          upstream: upstream,
        );
        await controller.loadProfile('test-printer');
        controller.setFlow(WizardFlow.freshFlash);
        // Pre-answer the question from a pre-wizard screen.
        await controller.setDecision('flash.os', 'debian-bookworm');

        // Must complete without ever emitting UserInputRequired.
        final inputs = <UserInputRequired>[];
        final sub = controller.events
            .where((e) => e is UserInputRequired)
            .cast<UserInputRequired>()
            .listen(inputs.add);

        await controller.startExecution();
        await sub.cancel();

        expect(inputs, isEmpty);
      },
    );

    test('auto-resolves disk_picker from flash.disk decision', () async {
      final controller = newController(
        profileJson: baseProfileJson(
          freshFlashSteps: [
            {'id': 'choose_target_disk', 'kind': 'disk_picker'},
          ],
        ),
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.freshFlash);
      await controller.setDecision('flash.disk', 'PhysicalDrive3');

      final inputs = <UserInputRequired>[];
      final sub = controller.events
          .where((e) => e is UserInputRequired)
          .cast<UserInputRequired>()
          .listen(inputs.add);
      await controller.startExecution();
      await sub.cancel();

      expect(inputs, isEmpty);
    });

    test('emits UserInputRequired when no prior decision was made', () async {
      final controller = newController(
        profileJson: baseProfileJson(
          freshFlashSteps: [
            {
              'id': 'flash_done_prompt',
              'kind': 'prompt',
              'message': 'All done',
            },
          ],
        ),
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.freshFlash);

      final completer = controller.events
          .where((e) => e is UserInputRequired)
          .cast<UserInputRequired>()
          .first;

      unawaited(controller.startExecution());
      final event = await completer.timeout(const Duration(seconds: 2));
      expect(event.stepId, 'flash_done_prompt');
      controller.resolveUserInput('flash_done_prompt', 'continue');
    });
  });

  group('WizardController cancellation', () {
    test('cancelExecution releases a pending user-input wait', () async {
      final controller = newController(
        profileJson: baseProfileJson(
          freshFlashSteps: [
            {
              'id': 'flash_done_prompt',
              'kind': 'prompt',
              'message': 'All done',
            },
          ],
        ),
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.freshFlash);

      final firstInput = controller.events
          .where((e) => e is UserInputRequired)
          .cast<UserInputRequired>()
          .first;

      final execution = controller.startExecution();
      final event = await firstInput.timeout(const Duration(seconds: 2));
      expect(event.stepId, 'flash_done_prompt');

      controller.cancelExecution(reason: 'scenario missing input');

      await expectLater(
        execution.timeout(const Duration(seconds: 2)),
        throwsA(
          isA<WizardCancelledException>().having(
            (e) => e.reason,
            'reason',
            'scenario missing input',
          ),
        ),
      );
    });
  });

  group('WizardController._runOsDownload', () {
    test(
      'streams progress and records flash.image_path + sha decision',
      () async {
        final upstream = FakeUpstream()
          ..addDownloadEvent(
            const OsDownloadProgress(
              bytesDone: 1000000,
              bytesTotal: 4000000,
              phase: OsDownloadPhase.downloading,
            ),
          )
          ..addDownloadEvent(
            const OsDownloadProgress(
              bytesDone: 0,
              bytesTotal: 0,
              phase: OsDownloadPhase.done,
              sha256: validImageSha,
            ),
          );

        final controller = newController(
          profileJson: baseProfileJson(
            freshFlashSteps: [
              {
                'id': 'download_os',
                'kind': 'os_download',
                'dest': 'C:/tmp/test.img',
              },
            ],
          ),
          upstream: upstream,
        );
        await controller.loadProfile('test-printer');
        controller.setFlow(WizardFlow.freshFlash);
        await controller.setDecision('flash.os', 'debian-bookworm');

        final progress = <StepProgress>[];
        final sub = controller.events
            .where((e) => e is StepProgress)
            .cast<StepProgress>()
            .listen(progress.add);

        await controller.startExecution();
        await sub.cancel();

        expect(
          controller.state.decisions['flash.image_path'],
          'C:/tmp/test.img',
        );
        expect(controller.state.decisions['flash.image_sha256'], validImageSha);
        expect(progress, hasLength(greaterThanOrEqualTo(2)));
        expect(progress.last.percent, 1.0);
      },
    );

    test(
      'rejects OS image profiles without an authenticated download',
      () async {
        final profile = baseProfileJson(
          freshFlashSteps: [
            {
              'id': 'download_os',
              'kind': 'os_download',
              'dest': 'C:/tmp/test.img',
            },
          ],
        );
        final options =
            ((profile['os'] as Map<String, dynamic>)['fresh_install_options']
                    as List)
                .cast<Map<String, dynamic>>();
        options.single.remove('sha256');

        final upstream = FakeUpstream();
        final controller = newController(
          profileJson: profile,
          upstream: upstream,
        );
        await controller.loadProfile('test-printer');
        controller.setFlow(WizardFlow.freshFlash);
        await controller.setDecision('flash.os', 'debian-bookworm');

        await expectLater(
          controller.startExecution(),
          throwsA(isA<StepExecutionException>()),
        );
        expect(upstream.downloadCalls, isEmpty);
      },
    );
  });

  group('WizardController._runFlashDisk', () {
    test(
      'throws StepExecutionException if helper service not configured',
      () async {
        final controller = newController(
          profileJson: baseProfileJson(
            freshFlashSteps: [
              {
                'id': 'flash_disk',
                'kind': 'flash_disk',
                'verify_after_write': true,
              },
            ],
          ),
        );
        await controller.loadProfile('test-printer');
        controller.setFlow(WizardFlow.freshFlash);
        await controller.setDecision('flash.disk', 'PhysicalDrive3');
        await controller.setDecision('flash.image_path', 'C:/tmp/test.img');

        await expectLater(
          controller.startExecution(),
          throwsA(isA<StepExecutionException>()),
        );
      },
    );

    test(
      'delegates to elevated helper, passes confirmation token + sha',
      () async {
        final flash = _StubFlashService();
        final helper = FakeElevatedHelper()
          ..addEvent(
            const FlashProgress(
              bytesDone: 2000000,
              bytesTotal: 4000000,
              phase: FlashPhase.writing,
            ),
          )
          ..addEvent(
            const FlashProgress(
              bytesDone: 4000000,
              bytesTotal: 4000000,
              phase: FlashPhase.done,
              message: 'abc123',
            ),
          );

        final security = FakeSecurity();

        final controller = newController(
          profileJson: baseProfileJson(
            freshFlashSteps: [
              {
                'id': 'flash_disk',
                'kind': 'flash_disk',
                'verify_after_write': true,
              },
            ],
          ),
          flash: flash,
          helper: helper,
          security: security,
        );
        await controller.loadProfile('test-printer');
        controller.setFlow(WizardFlow.freshFlash);
        await controller.setDecision('flash.disk', 'PhysicalDrive3');
        await controller.setDecision('flash.image_path', 'C:/tmp/test.img');
        await controller.setDecision('flash.image_sha256', 'abc123');

        await controller.startExecution();

        expect(helper.calls, hasLength(1));
        expect(flash.safetyChecks, ['PhysicalDrive3']);
        expect(helper.calls.first.diskId, 'PhysicalDrive3');
        expect(helper.calls.first.imagePath, 'C:/tmp/test.img');
        expect(helper.calls.first.verifyAfterWrite, true);
        expect(helper.calls.first.expectedSha256, 'abc123');
        expect(helper.calls.first.confirmationToken, security.lastTokenValue);
      },
    );

    test('refuses to launch helper when disk safety blocks', () async {
      final flash = _StubFlashService(
        safetyVerdict: const FlashSafetyVerdict(
          diskId: 'PhysicalDrive3',
          allowed: false,
          blockingReasons: ['system mount detected'],
        ),
      );
      final helper = FakeElevatedHelper();
      final security = FakeSecurity();
      final controller = newController(
        profileJson: baseProfileJson(
          freshFlashSteps: [
            {'id': 'flash_disk', 'kind': 'flash_disk'},
          ],
        ),
        flash: flash,
        helper: helper,
        security: security,
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.freshFlash);
      await controller.setDecision('flash.disk', 'PhysicalDrive3');
      await controller.setDecision('flash.image_path', 'C:/tmp/test.img');

      await expectLater(
        controller.startExecution(),
        throwsA(isA<StepExecutionException>()),
      );
      expect(flash.safetyChecks, ['PhysicalDrive3']);
      expect(helper.calls, isEmpty);
      expect(security.lastTokenValue, isEmpty);
    });

    test(
      'refuses to launch helper on unacknowledged safety warnings',
      () async {
        final flash = _StubFlashService(
          safetyVerdict: const FlashSafetyVerdict(
            diskId: 'PhysicalDrive3',
            allowed: true,
            warnings: ['disk is large'],
          ),
        );
        final helper = FakeElevatedHelper();
        final security = FakeSecurity();
        final controller = newController(
          profileJson: baseProfileJson(
            freshFlashSteps: [
              {'id': 'flash_disk', 'kind': 'flash_disk'},
            ],
          ),
          flash: flash,
          helper: helper,
          security: security,
        );
        await controller.loadProfile('test-printer');
        controller.setFlow(WizardFlow.freshFlash);
        await controller.setDecision('flash.disk', 'PhysicalDrive3');
        await controller.setDecision('flash.image_path', 'C:/tmp/test.img');

        await expectLater(
          controller.startExecution(),
          throwsA(isA<StepExecutionException>()),
        );
        expect(helper.calls, isEmpty);
        expect(security.lastTokenValue, isEmpty);
      },
    );

    test(
      'allows helper launch after disk-specific safety warning acknowledgement',
      () async {
        final flash = _StubFlashService(
          safetyVerdict: const FlashSafetyVerdict(
            diskId: 'PhysicalDrive3',
            allowed: true,
            warnings: ['disk is larger than expected'],
          ),
        );
        final helper = FakeElevatedHelper()
          ..addEvent(
            const FlashProgress(
              bytesDone: 1,
              bytesTotal: 1,
              phase: FlashPhase.done,
              message: 'abc123',
            ),
          );
        final security = FakeSecurity();
        final controller = newController(
          profileJson: baseProfileJson(
            freshFlashSteps: [
              {'id': 'flash_disk', 'kind': 'flash_disk'},
            ],
          ),
          flash: flash,
          helper: helper,
          security: security,
        );
        await controller.loadProfile('test-printer');
        controller.setFlow(WizardFlow.freshFlash);
        await controller.setDecision('flash.disk', 'PhysicalDrive3');
        await controller.setDecision('flash.image_path', 'C:/tmp/test.img');
        await controller.setDecision(
          'flash.safety_warnings_acknowledged.PhysicalDrive3',
          true,
        );

        await controller.startExecution();

        expect(flash.safetyChecks, ['PhysicalDrive3']);
        expect(helper.calls, hasLength(1));
        expect(helper.calls.single.diskId, 'PhysicalDrive3');
        expect(helper.calls.single.confirmationToken, security.lastTokenValue);
      },
    );
  });

  group('WizardController script step kind', () {
    test('uploads + executes script via ssh, surfaces failures', () async {
      final ssh = FakeSsh()
        ..nextRun = const SshCommandResult(
          stdout: 'ok',
          stderr: '',
          exitCode: 0,
        );
      final controller = newController(
        profileJson: baseProfileJson(
          stockKeepSteps: [
            {'id': 'sh', 'kind': 'script', 'path': 'scripts/noop.sh'},
          ],
        ),
        ssh: ssh,
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);
      // Skip the SSH connect step - stub a session manually.
      await controller.connectSsh(host: '127.0.0.1');

      // ssh service won't actually read the script path; pre-check it.
      // Instead we set nextRun to succeed and rely on the fact that the
      // controller's _runScript throws on a missing local file before
      // calling ssh.run. So we expect a StepExecutionException.
      await expectLater(
        controller.startExecution(),
        throwsA(isA<StepExecutionException>()),
      );
    });

    test(
      'resolves shared/ paths against the repo root, not profile dir',
      () async {
        // Simulate the real cache layout: <tmp>/<repo>/printers/<id>/
        final repoRoot = await Directory.systemTemp.createTemp(
          'deckhand-repo-',
        );
        final sharedDir = Directory(p.join(repoRoot.path, 'shared', 'scripts'));
        await sharedDir.create(recursive: true);
        final scriptPath = p.join(sharedDir.path, 'build-python.sh');
        await File(scriptPath).writeAsString('#!/bin/sh\nexit 0\n');

        final profileDir = Directory(
          p.join(repoRoot.path, 'printers', 'test-printer'),
        );
        await profileDir.create(recursive: true);

        final ssh = FakeSsh();
        final controller = WizardController(
          profiles: _PinnedLocationProfileService(
            baseProfileJson(
              stockKeepSteps: [
                {
                  'id': 'sh',
                  'kind': 'script',
                  'path': 'shared/scripts/build-python.sh',
                },
              ],
            ),
            profileDirPath: profileDir.path,
          ),
          ssh: ssh,
          flash: _StubFlashService(),
          discovery: _StubDiscoveryService(),
          moonraker: _StubMoonrakerService(),
          upstream: FakeUpstream(),
          security: FakeSecurity(),
        );
        await controller.loadProfile('test-printer');
        controller.setFlow(WizardFlow.stockKeep);
        await controller.connectSsh(host: '127.0.0.1');
        // Must not throw the "script not found" error even though the
        // script lives at <repo>/shared/..., not <profile>/shared/....
        await controller.startExecution();
        expect(
          ssh.runCalls.any(
            (c) => RegExp(
              r'bash /tmp/deckhand-[0-9a-f]+-build-python\.sh',
            ).hasMatch(c),
          ),
          isTrue,
        );

        await repoRoot.delete(recursive: true);
      },
    );

    test(
      'script default: sudo:false + askpass helper staged; internal sudos work',
      () async {
        final tmp = await _stageLocalScript('noop.sh');
        final ssh = FakeSsh()
          ..nextRun = const SshCommandResult(
            stdout: 'done',
            stderr: '',
            exitCode: 0,
          );
        final controller = newController(
          profileJson: baseProfileJson(
            stockKeepSteps: [
              {
                'id': 'sh',
                'kind': 'script',
                'path': tmp,
                'args': ['--fast'],
              },
            ],
          ),
          ssh: ssh,
        );
        await controller.loadProfile('test-printer');
        controller.setFlow(WizardFlow.stockKeep);
        await controller.connectSsh(host: '127.0.0.1');
        await controller.startExecution();

        // Upload count: script + askpass helper + sudo wrapper.
        expect(ssh.uploadCalls, hasLength(3));
        final uploadedTargets = ssh.uploadCalls.map((u) => u.remote).toList();
        expect(
          uploadedTargets.any((r) => r.startsWith('/tmp/deckhand-askpass-')),
          isTrue,
          reason: 'askpass helper must be staged on remote',
        );
        expect(
          uploadedTargets.any(
            (r) => r.startsWith('/tmp/deckhand-bin-') && r.endsWith('/sudo'),
          ),
          isTrue,
          reason: 'sudo wrapper must be placed on remote PATH',
        );

        // Askpass content prints the cached password.
        final askpass = ssh.uploadCalls.firstWhere(
          (u) => u.remote.startsWith('/tmp/deckhand-askpass-'),
        );
        expect(askpass.content, contains("printf '%s' 'root'"));

        // Sudo wrapper forwards to real sudo with -A.
        final wrapper = ssh.uploadCalls.firstWhere(
          (u) => u.remote.endsWith('/sudo'),
        );
        expect(wrapper.content, contains('exec /usr/bin/sudo -A'));

        // The run command sets SUDO_ASKPASS + PATH prefix and points
        // at the user-space script (no outer sudo).
        final runCmd = ssh.runCalls.firstWhere(
          (c) => RegExp(r'bash /tmp/deckhand-[0-9a-f]+-noop\.sh').hasMatch(c),
        );
        expect(runCmd, contains('SUDO_ASKPASS=\'/tmp/deckhand-askpass-'));
        expect(runCmd, contains('PATH=\'/tmp/deckhand-bin-'));
        expect(runCmd, isNot(startsWith('-E ')));
        expect(runCmd, contains('--fast'));

        // Cleanup is deferred to controller.dispose() so repeated
        // script steps reuse the same helper. Verify it happens then.
        final pre = ssh.runCalls.length;
        await controller.dispose();
        final cleanup = ssh.runCalls
            .sublist(pre)
            .where((c) => c.startsWith('rm -rf'))
            .toList();
        expect(cleanup, hasLength(1));
        expect(cleanup.single, contains('deckhand-askpass-'));
        expect(cleanup.single, contains('deckhand-bin-'));
      },
    );

    test(
      'sudo:true + askpass routes the outer sudo through askpass (-A -E)',
      () async {
        final tmp = await _stageLocalScript('rebuild.sh');
        final ssh = FakeSsh()
          ..nextRun = const SshCommandResult(
            stdout: '',
            stderr: '',
            exitCode: 0,
          );
        final controller = newController(
          profileJson: baseProfileJson(
            stockKeepSteps: [
              {'id': 'sh', 'kind': 'script', 'path': tmp, 'sudo': true},
            ],
          ),
          ssh: ssh,
        );
        await controller.loadProfile('test-printer');
        controller.setFlow(WizardFlow.stockKeep);
        await controller.connectSsh(host: '127.0.0.1');
        await controller.startExecution();

        // Outer `sudo -A -E` so sudo uses askpass, not a pty prompt.
        // The whole command is env-prefixed so _runSsh does NOT strip
        // it and does NOT forward via -S (that would be redundant).
        // Use stepDetails per-call lookup so the background probe's
        // overwrite of `lastSudoPassword` can't flake the assertion.
        final call = ssh.stepDetails.firstWhere(
          (d) => RegExp(
            r'bash /tmp/deckhand-[0-9a-f]+-rebuild\.sh',
          ).hasMatch(d.command),
        );
        expect(call.command, contains('SUDO_ASKPASS=\'/tmp/deckhand-askpass-'));
        expect(
          call.command,
          matches(
            RegExp(r'sudo -A -E bash /tmp/deckhand-[0-9a-f]+-rebuild\.sh'),
          ),
        );
        expect(call.sudoPassword, isNull);
      },
    );

    test('script with askpass:false skips helper staging entirely', () async {
      final tmp = await _stageLocalScript('pure.sh');
      final ssh = FakeSsh()
        ..nextRun = const SshCommandResult(stdout: '', stderr: '', exitCode: 0);
      final controller = newController(
        profileJson: baseProfileJson(
          stockKeepSteps: [
            {'id': 'sh', 'kind': 'script', 'path': tmp, 'askpass': false},
          ],
        ),
        ssh: ssh,
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);
      await controller.connectSsh(host: '127.0.0.1');
      await controller.startExecution();

      // Only the script itself is uploaded, nothing else.
      expect(ssh.uploadCalls, hasLength(1));
      expect(
        ssh.uploadCalls.single.remote,
        matches(RegExp(r'^/tmp/deckhand-[0-9a-f]+-pure\.sh$')),
      );
      expect(
        ssh.steps.single,
        matches(RegExp(r'^bash /tmp/deckhand-[0-9a-f]+-pure\.sh$')),
      );
    });

    test('rejects multi-word script interpreters before upload', () async {
      final tmp = await _stageLocalScript('injected.sh');
      final ssh = FakeSsh();
      final controller = newController(
        profileJson: baseProfileJson(
          stockKeepSteps: [
            {
              'id': 'sh',
              'kind': 'script',
              'path': tmp,
              'interpreter': 'bash; touch /tmp/pwned',
            },
          ],
        ),
        ssh: ssh,
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);
      await controller.connectSsh(host: '127.0.0.1');

      await expectLater(
        controller.startExecution(),
        throwsA(isA<StepExecutionException>()),
      );
      expect(ssh.uploadCalls, isEmpty);
      expect(ssh.steps.any((c) => c.contains('/tmp/pwned')), isFalse);
    });

    test(
      'script with sudo:true AND no askpass uses sudoPassword forwarding',
      () async {
        final tmp = await _stageLocalScript('rebuild.sh');
        final ssh = FakeSsh()
          ..nextRun = const SshCommandResult(
            stdout: '',
            stderr: '',
            exitCode: 0,
          );
        final controller = newController(
          profileJson: baseProfileJson(
            stockKeepSteps: [
              {
                'id': 'sh',
                'kind': 'script',
                'path': tmp,
                'sudo': true,
                'askpass': false,
              },
            ],
          ),
          ssh: ssh,
        );
        await controller.loadProfile('test-printer');
        controller.setFlow(WizardFlow.stockKeep);
        await controller.connectSsh(host: '127.0.0.1');
        await controller.startExecution();

        // No askpass staging: only the script itself is uploaded.
        expect(ssh.uploadCalls, hasLength(1));
        // `sudo -E bash ...` -> _runSsh strips `sudo ` and forwards
        // the password via the sudoPassword parameter. Look up per-
        // call via stepDetails so the background probe can't overwrite
        // our lastSudoPassword observation.
        final call = ssh.stepDetails.singleWhere(
          (d) => RegExp(
            r'bash /tmp/deckhand-[0-9a-f]+-rebuild\.sh',
          ).hasMatch(d.command),
        );
        expect(
          call.command,
          matches(RegExp(r'^-E bash /tmp/deckhand-[0-9a-f]+-rebuild\.sh$')),
        );
        expect(call.sudoPassword, 'root');
      },
    );
  });

  group('WizardController._runSsh', () {
    test('strips `sudo ` prefix and forwards password', () async {
      final ssh = FakeSsh();
      final controller = newController(
        profileJson: baseProfileJson(
          stockKeepSteps: [
            {
              'id': 'probe',
              'kind': 'ssh_commands',
              'commands': ['sudo systemctl status klipper'],
            },
          ],
        ),
        ssh: ssh,
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);
      await controller.connectSsh(host: '127.0.0.1');
      await controller.startExecution();

      final call = ssh.stepDetails.singleWhere(
        (d) => d.command == 'systemctl status klipper',
      );
      expect(call.sudoPassword, 'root');
    });

    test('leaves non-sudo commands untouched', () async {
      final ssh = FakeSsh();
      final controller = newController(
        profileJson: baseProfileJson(
          stockKeepSteps: [
            {
              'id': 'probe',
              'kind': 'ssh_commands',
              'commands': ['ls /home/mks'],
            },
          ],
        ),
        ssh: ssh,
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);
      await controller.connectSsh(host: '127.0.0.1');
      await controller.startExecution();

      final call = ssh.stepDetails.singleWhere(
        (d) => d.command == 'ls /home/mks',
      );
      expect(call.sudoPassword, isNull);
    });
  });

  group('WizardController._runWriteFile', () {
    test('auto-detects system path and uses sudo install', () async {
      final ssh = FakeSsh();
      final controller = newController(
        profileJson: baseProfileJson(
          stockKeepSteps: [
            {
              'id': 'apt',
              'kind': 'write_file',
              'target': '/etc/apt/sources.list',
              'content': 'deb http://deb.debian.org/debian bookworm main',
              'mode': '0644',
              'owner': 'root',
              // Disable the auto-backup step so this test asserts on
              // the write operation in isolation. There's a dedicated
              // auto-backup test below.
              'backup': false,
            },
          ],
        ),
        ssh: ssh,
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);
      await controller.connectSsh(host: '127.0.0.1');
      await controller.startExecution();

      // One upload (to /tmp), one install command (sudo-wrapped then
      // sudo-stripped by _runSsh). Look up per-call via stepDetails
      // so the background state probe can't overwrite lastSudoPassword
      // mid-flight.
      expect(ssh.uploadCalls, hasLength(1));
      expect(ssh.uploadCalls.single.remote, startsWith('/tmp/deckhand-write-'));
      final call = ssh.stepDetails.singleWhere(
        (d) =>
            d.command.contains('/etc/apt/sources.list') &&
            d.command.startsWith('install '),
      );
      expect(call.command, startsWith('install -m 644 '));
      expect(call.command, contains("-o 'root' "));
      expect(call.sudoPassword, 'root');
    });

    test('home path does not sudo', () async {
      final ssh = FakeSsh();
      final controller = newController(
        profileJson: baseProfileJson(
          stockKeepSteps: [
            {
              'id': 'hook',
              'kind': 'write_file',
              'target': '/home/root/startup.sh',
              'content': '#!/bin/sh\nexit 0',
              'mode': '0755',
              'backup': false,
            },
          ],
        ),
        ssh: ssh,
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);
      await controller.connectSsh(host: '127.0.0.1');
      await controller.startExecution();

      // Non-system path: plain mv + chmod, no sudo.
      final call = ssh.stepDetails.singleWhere(
        (d) =>
            d.command.startsWith('mv ') &&
            d.command.contains('/home/root/startup.sh'),
      );
      expect(call.command, contains('chmod 755'));
      expect(call.sudoPassword, isNull);
    });

    test('auto-backup write-probe uses touch+rm to detect RO mounts', () async {
      final ssh = FakeSsh();
      final controller = newController(
        profileJson: baseProfileJson(
          stockKeepSteps: [
            {
              'id': 'apt',
              'kind': 'write_file',
              'target': '/etc/apt/sources.list',
              'content': 'deb http://deb.debian.org/debian trixie main',
              'mode': '0644',
            },
          ],
        ),
        ssh: ssh,
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);
      await controller.connectSsh(host: '127.0.0.1');
      await controller.startExecution();

      // The backup shell script must write-probe via touch+rm so we
      // catch RO bind-mounts whose parent dir reports writable via
      // `-w` but reject actual writes. Confirm the command uses the
      // touch+rm sentinel rather than the old `[ ! -w "$(dirname ...)"
      // ]` shape.
      final backupCmd = ssh.steps.firstWhere((c) => c.contains('cp -p'));
      expect(backupCmd, contains('touch '));
      expect(
        backupCmd,
        contains('DECKHAND_BACKUP_RO_FS'),
        reason: 'the sentinel branch must exist in the generated cmd',
      );
      // And the legacy heuristic should be gone.
      expect(
        backupCmd,
        isNot(contains(r'-w "$(dirname')),
        reason:
            'old parent-dir -w heuristic should be replaced by '
            'the touch+rm real-write test',
      );
    });

    test('auto-backup snapshots existing file before overwriting', () async {
      final ssh = FakeSsh();
      final controller = newController(
        profileJson: baseProfileJson(
          stockKeepSteps: [
            {
              'id': 'apt',
              'kind': 'write_file',
              'target': '/etc/apt/sources.list',
              'content': 'deb http://deb.debian.org/debian bookworm main',
              'mode': '0644',
              'owner': 'root',
              // backup default is true; omitting the key tests that.
            },
          ],
        ),
        ssh: ssh,
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);
      await controller.connectSsh(host: '127.0.0.1');
      await controller.startExecution();

      // The backup step runs BEFORE the install: it probes whether
      // the target exists, does RO-FS detection, then cp -p's it
      // sideways. Must be sudo-wrapped for system paths and point at
      // a suffixed sibling.
      final backup = ssh.steps.firstWhere((c) => c.contains('cp -p'));
      // The new command distinguishes three outcomes:
      //   DECKHAND_BACKUP_NOOP    (target did not exist)
      //   DECKHAND_BACKUP_RO_FS   (target dir not writable + no sudo)
      //   DECKHAND_BACKUP_CREATED (backup + meta sidecar written)
      expect(backup, contains('if [ ! -e '));
      expect(backup, contains('DECKHAND_BACKUP_NOOP'));
      expect(backup, contains('DECKHAND_BACKUP_RO_FS'));
      expect(backup, contains('DECKHAND_BACKUP_CREATED'));
      expect(backup, contains('/etc/apt/sources.list'));
      expect(backup, contains('.deckhand-pre-'));
      // New naming: includes the profile id as a tag.
      expect(backup, contains('test-printer'));
      // Metadata sidecar gets written alongside the backup. Since we
      // now SFTP-upload the JSON instead of inlining it into a shell
      // `printf %s ... > file` command, the backup command itself
      // references the `.meta.json` target but NOT the JSON body;
      // the body is on the upload side.
      expect(backup, contains('.meta.json'));
      // The JSON payload itself lives on the upload channel now.
      final metaUpload = ssh.uploadCalls.firstWhere(
        (u) => u.remote.contains('deckhand-meta-'),
      );
      expect(metaUpload.content, contains('"profile_id": "test-printer"'));
      expect(metaUpload.content, contains('"deckhand_schema": 1'));
    });

    test(
      'write_file require_path gates the write on a live precondition',
      () async {
        final ssh = FakeSsh()
          // First [ -e ... ] check returns 'n' to indicate the required
          // path is missing.
          ..nextRun = const SshCommandResult(
            stdout: 'n',
            stderr: '',
            exitCode: 0,
          );
        final controller = newController(
          profileJson: baseProfileJson(
            stockKeepSteps: [
              {
                'id': 'hook',
                'kind': 'write_file',
                'target': '/home/root/missing/hook.sh',
                'require_path': '/home/root/missing',
                'content': '#!/bin/sh\nexit 0',
                'backup': false,
              },
            ],
          ),
          ssh: ssh,
        );
        await controller.loadProfile('test-printer');
        controller.setFlow(WizardFlow.stockKeep);
        await controller.connectSsh(host: '127.0.0.1');
        await controller.startExecution();
        // Only the precondition check ran; no mv / install / cp.
        final nonProbe = ssh.steps;
        expect(nonProbe.any((c) => c.contains('[ -e ')), isTrue);
        expect(
          nonProbe.any((c) => c.contains('install -m')),
          isFalse,
          reason: 'write_file should have skipped when require_path missing',
        );
      },
    );
  });

  group('WizardController.restoreBackup / deleteBackup / pruneBackups', () {
    test(
      'restoreBackup routed through _runSsh, sudo-stripped for system path',
      () async {
        final ssh = FakeSsh();
        final controller = newController(
          profileJson: baseProfileJson(),
          ssh: ssh,
        );
        await controller.loadProfile('test-printer');
        await controller.connectSsh(host: '127.0.0.1');
        await controller.restoreBackup(
          const DeckhandBackup(
            originalPath: '/etc/apt/sources.list',
            backupPath: '/etc/apt/sources.list.deckhand-pre-1776',
          ),
        );
        // Find the cp -p call. Since _runSsh strips the outer `sudo `
        // before passing to the SshService, the captured command
        // STARTS with `cp -p`.
        final cp = ssh.steps.firstWhere((c) => c.contains('cp -p'));
        expect(cp, startsWith('cp -p'));
        expect(cp, contains('/etc/apt/sources.list'));
        // Inner chown preserves ownership from the backup's metadata
        // (belt-and-suspenders over cp -p's own preservation).
        expect(cp, contains('chown --reference='));
      },
    );

    test(
      'restoreBackup forwards the SSH password on the cp call specifically',
      () async {
        final ssh = FakeSsh();
        final controller = newController(
          profileJson: baseProfileJson(),
          ssh: ssh,
        );
        await controller.loadProfile('test-printer');
        await controller.connectSsh(host: '127.0.0.1');
        await controller.restoreBackup(
          const DeckhandBackup(
            originalPath: '/etc/apt/sources.list',
            backupPath: '/etc/apt/sources.list.deckhand-pre-1776',
          ),
        );
        // Use per-call details so we can pin the sudoPassword on the
        // specific cp call. lastSudoPassword would be overwritten by
        // the post-restore force-reprobe (which doesn't use sudo).
        final cpCall = ssh.stepDetails.firstWhere(
          (d) =>
              d.command.contains('cp -p') &&
              d.command.contains('/etc/apt/sources.list'),
        );
        expect(
          cpCall.sudoPassword,
          'root',
          reason:
              'Must forward the cached SSH password to sudo via -S '
              'when the original path is root-owned.',
        );
      },
    );

    test(
      'restoreBackup stays unprivileged for paths under the user home',
      () async {
        final ssh = FakeSsh();
        final controller = newController(
          profileJson: baseProfileJson(),
          ssh: ssh,
        );
        await controller.loadProfile('test-printer');
        await controller.connectSsh(host: '127.0.0.1');
        await controller.restoreBackup(
          const DeckhandBackup(
            originalPath: '/home/root/printer.cfg',
            backupPath: '/home/root/printer.cfg.deckhand-pre-1776',
          ),
        );
        final cp = ssh.steps.firstWhere((c) => c.contains('cp -p'));
        expect(cp, startsWith('cp -p'));
        expect(cp, isNot(contains('sudo')));
      },
    );

    test('deleteBackup removes both the backup file AND its sidecar', () async {
      final ssh = FakeSsh();
      final controller = newController(
        profileJson: baseProfileJson(),
        ssh: ssh,
      );
      await controller.loadProfile('test-printer');
      await controller.connectSsh(host: '127.0.0.1');
      await controller.deleteBackup(
        const DeckhandBackup(
          originalPath: '/etc/apt/sources.list',
          backupPath: '/etc/apt/sources.list.deckhand-pre-1776',
        ),
      );
      final rm = ssh.steps.firstWhere((c) => c.contains('rm -f'));
      expect(rm, contains('.deckhand-pre-1776'));
      expect(rm, contains('.meta.json'));
    });

    test('pruneBackups batches into one rm per privilege bucket', () async {
      final ssh = FakeSsh();
      final controller = newController(
        profileJson: baseProfileJson(),
        ssh: ssh,
      );
      await controller.loadProfile('test-printer');
      await controller.connectSsh(host: '127.0.0.1');
      // Seed three backups: two old + system (one rm call with sudo),
      // one old + in-home (one rm call without sudo), plus one fresh
      // (should NOT be deleted).
      final old = DateTime.now().subtract(const Duration(days: 60));
      final fresh = DateTime.now().subtract(const Duration(days: 5));
      controller.printerStateForTesting = PrinterState(
        services: const {},
        files: const {},
        paths: const {},
        stackInstalls: const {},
        screenInstalls: const {},
        python311Installed: false,
        deckhandBackups: [
          DeckhandBackup(
            originalPath: '/etc/apt/sources.list',
            backupPath: '/etc/apt/sources.list.deckhand-pre-1',
            createdAt: old,
          ),
          DeckhandBackup(
            originalPath: '/etc/default/grub',
            backupPath: '/etc/default/grub.deckhand-pre-2',
            createdAt: old,
          ),
          DeckhandBackup(
            originalPath: '/home/root/printer.cfg',
            backupPath: '/home/root/printer.cfg.deckhand-pre-3',
            createdAt: old,
          ),
          DeckhandBackup(
            originalPath: '/etc/hostname',
            backupPath: '/etc/hostname.deckhand-pre-4',
            createdAt: fresh,
          ),
        ],
        probedAt: DateTime.now(),
      );

      final n = await controller.pruneBackups();
      expect(n, 3);

      // Exactly two rm commands: sudo-batch and plain-batch.
      final rms = ssh.steps.where((c) => c.contains('rm -f')).toList();
      expect(rms, hasLength(2));
      expect(rms.any((c) => c.contains('/etc/apt/sources.list')), isTrue);
      expect(rms.any((c) => c.contains('/etc/default/grub')), isTrue);
      expect(rms.any((c) => c.contains('/home/root/printer.cfg')), isTrue);
      expect(
        rms.any((c) => c.contains('/etc/hostname')),
        isFalse,
        reason: 'Fresh backup must survive the prune',
      );
      // Sidecars included in the prune.
      expect(rms.any((c) => c.contains('.meta.json')), isTrue);
    });

    test(
      'pruneBackups keepLatestPerTarget spares the newest per target',
      () async {
        final ssh = FakeSsh();
        final controller = newController(
          profileJson: baseProfileJson(),
          ssh: ssh,
        );
        await controller.loadProfile('test-printer');
        await controller.connectSsh(host: '127.0.0.1');
        // Two backups of the SAME target, both old. Without keepLatest
        // both would be pruned; with it, the newer survives.
        final older = DateTime.now().subtract(const Duration(days: 90));
        final newer = DateTime.now().subtract(const Duration(days: 60));
        controller.printerStateForTesting = PrinterState(
          services: const {},
          files: const {},
          paths: const {},
          stackInstalls: const {},
          screenInstalls: const {},
          python311Installed: false,
          deckhandBackups: [
            DeckhandBackup(
              originalPath: '/etc/apt/sources.list',
              backupPath: '/etc/apt/sources.list.deckhand-pre-older',
              createdAt: older,
            ),
            DeckhandBackup(
              originalPath: '/etc/apt/sources.list',
              backupPath: '/etc/apt/sources.list.deckhand-pre-newer',
              createdAt: newer,
            ),
          ],
          probedAt: DateTime.now(),
        );
        final n = await controller.pruneBackups(keepLatestPerTarget: true);
        expect(n, 1);
        final rm = ssh.steps.firstWhere((c) => c.contains('rm -f'));
        expect(rm, contains('deckhand-pre-older'));
        expect(rm, isNot(contains('deckhand-pre-newer')));
      },
    );

    test(
      'pruneBackups with nothing to do returns 0 and does not touch ssh',
      () async {
        final ssh = FakeSsh();
        final controller = newController(
          profileJson: baseProfileJson(),
          ssh: ssh,
        );
        await controller.loadProfile('test-printer');
        await controller.connectSsh(host: '127.0.0.1');
        // No backups at all.
        final beforeCount = ssh.steps.length;
        final n = await controller.pruneBackups();
        expect(n, 0);
        // No new ssh.run calls beyond whatever the probe did.
        expect(ssh.steps.length, beforeCount);
      },
    );

    group('looksLikeBinary classifier', () {
      test('file --mime charset=binary => binary', () {
        expect(
          WizardController.looksLikeBinary(
            'application/x-executable; charset=binary',
          ),
          isTrue,
        );
      });

      test(
        'file --mime application/octet-stream WITHOUT charset => binary',
        () {
          expect(
            WizardController.looksLikeBinary('application/octet-stream'),
            isTrue,
          );
        },
      );

      test('busybox file (no --mime) emits descriptive keywords', () {
        for (final sample in [
          'ELF 64-bit LSB pie executable, ARM aarch64',
          'Zip archive data, at least v2.0 to extract',
          'gzip compressed data, was "printer.cfg"',
          'PNG image data, 512 x 512, 8-bit/color RGBA',
          'data', // busybox fallback label
        ]) {
          expect(
            WizardController.looksLikeBinary(sample),
            isTrue,
            reason: 'should classify "$sample" as binary',
          );
        }
      });

      test('od output with null-byte glyphs => binary', () {
        expect(
          WizardController.looksLikeBinary('   \\0   \\0   \\0  a   b   c'),
          isTrue,
        );
      });

      test('plain text returns false', () {
        for (final sample in [
          'text/plain; charset=utf-8',
          'ASCII text',
          'UTF-8 Unicode text, with very long lines',
        ]) {
          expect(
            WizardController.looksLikeBinary(sample),
            isFalse,
            reason: 'should classify "$sample" as text',
          );
        }
      });

      test('empty probe output returns false (file(1) missing everywhere)', () {
        expect(WizardController.looksLikeBinary(''), isFalse);
      });
    });

    test('readBackupContent caps at maxLines when body is long', () async {
      final longBody = List<String>.generate(500, (i) => 'line$i').join('\n');
      final ssh = FakeSsh();
      // Probe-then-read pattern: first run is the binary probe
      // (returns text/plain), second is the head -c read. We can't
      // easily differentiate responses per-run with nextRun alone, so
      // set both to the body - the text classifier short-circuits on
      // the text mime and we use the long body for the read result.
      ssh.nextRun = SshCommandResult(stdout: longBody, stderr: '', exitCode: 0);
      final controller = newController(
        profileJson: baseProfileJson(),
        ssh: ssh,
      );
      await controller.loadProfile('test-printer');
      await controller.connectSsh(host: '127.0.0.1');
      // First call: probe returns longBody -> classifier sees no
      // binary markers -> text-read path. Second call returns same
      // body -> we cap at 200 lines.
      final result = await controller.readBackupContent(
        const DeckhandBackup(
          originalPath: '/home/mks/x',
          backupPath: '/home/mks/x.deckhand-pre-1',
        ),
      );
      // The truncation notice fires when lines > 200.
      expect(result, isNotNull);
      expect(result, contains('truncated at 200 lines'));
      expect(result, contains('file has 500 lines total'));
    });

    test(
      'readBackupContent runs binary-probe then text-read via sudo',
      () async {
        final ssh = FakeSsh()
          ..nextRun = const SshCommandResult(
            stdout: 'text/plain; charset=utf-8',
            stderr: '',
            exitCode: 0,
          );
        final controller = newController(
          profileJson: baseProfileJson(),
          ssh: ssh,
        );
        await controller.loadProfile('test-printer');
        await controller.connectSsh(host: '127.0.0.1');
        await controller.readBackupContent(
          const DeckhandBackup(
            originalPath: '/etc/apt/sources.list',
            backupPath: '/etc/apt/sources.list.deckhand-pre-1',
          ),
        );
        // Step 1: file -b --mime on the backup (for binary detection).
        expect(
          ssh.steps.any((c) => c.contains('file -b --mime')),
          isTrue,
          reason: 'must run MIME probe before reading content',
        );
        // Step 2: head -c 262144 to read the body with a byte cap.
        expect(
          ssh.steps.any((c) => c.contains('head -c 262144')),
          isTrue,
          reason: 'must cap the body read at 256 KiB',
        );
      },
    );

    test(
      'readBackupContent returns a marker string for binary backups',
      () async {
        final ssh = FakeSsh()
          ..nextRun = const SshCommandResult(
            stdout: 'application/octet-stream; charset=binary',
            stderr: '',
            exitCode: 0,
          );
        final controller = newController(
          profileJson: baseProfileJson(),
          ssh: ssh,
        );
        await controller.loadProfile('test-printer');
        await controller.connectSsh(host: '127.0.0.1');
        final content = await controller.readBackupContent(
          const DeckhandBackup(
            originalPath: '/etc/apt/sources.list',
            backupPath: '/etc/apt/sources.list.deckhand-pre-1',
          ),
        );
        expect(content, contains('binary file'));
        expect(content, contains('preview unavailable'));
      },
    );
  });

  group('WizardController._runInstallMarker', () {
    test('writes JSON marker under Moonraker config root', () async {
      final ssh = FakeSsh();
      final controller = newController(
        profileJson: baseProfileJson(
          stockKeepSteps: [
            {'id': 'mark', 'kind': 'install_marker'},
          ],
        ),
        ssh: ssh,
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);
      await controller.connectSsh(host: '127.0.0.1');
      await controller.startExecution();

      // Filter out the background state-probe call that fires on
      // connect - it's a multi-line `#!/bin/sh` script and isn't
      // part of what this test cares about.
      final relevant = ssh.runCalls
          .where((c) => !c.startsWith('#!/bin/sh'))
          .toList();
      expect(
        relevant.any(
          (c) =>
              c.startsWith('mkdir -p ') &&
              c.contains('/home/root/printer_data/config'),
        ),
        isTrue,
      );
      expect(
        relevant.any(
          (c) => c.startsWith('mv ') && c.contains('/deckhand.json'),
        ),
        isTrue,
      );

      // The payload must contain the profile id + schema version.
      // The install_marker flow may stage a backup metadata sidecar
      // alongside the main JSON marker; locate the marker specifically
      // by its remote destination (the sidecar uses a /tmp staging
      // path, the marker uses the final /tmp/deckhand-write-<ts>
      // path).
      final markerUpload = ssh.uploadCalls.firstWhere(
        (u) => u.remote.contains('/tmp/deckhand-write-'),
      );
      expect(markerUpload.content, contains('"profile_id": "test-printer"'));
      expect(markerUpload.content, contains('"deckhand_schema": 1'));
    });
  });

  group('install_stack regression', () {
    // Regression for the production bug: install_stack received the
    // literal string "{{stack.webui.selected}}" as a component name
    // and threw `unknown stack component {{stack.webui.selected}}`
    // because the template wasn't being expanded against the user's
    // webui decision. Production caught this only by walking the GUI
    // halfway through an install on a real printer.
    test('expands {{stack.webui.selected}} from the webui decision', () async {
      final ssh = FakeSsh();
      final upstream = FakeUpstream();
      final controller = newController(
        profileJson: {
          ...baseProfileJson(
            stockKeepSteps: [
              {
                'id': 'install_stack',
                'kind': 'install_stack',
                'components': [
                  'moonraker',
                  '{{stack.webui.selected}}',
                  'kiauh',
                ],
              },
            ],
          ),
          'stack': {
            'moonraker': {
              'repo': 'https://github.com/Arksine/moonraker',
              'install_path': '~/moonraker',
            },
            'kiauh': {
              'repo': 'https://github.com/dw-0/kiauh',
              'install_path': '~/kiauh',
            },
            'webui': {
              'choices': [
                {
                  'id': 'fluidd',
                  'release_repo': 'fluidd-core/fluidd',
                  'tag': 'v1.34.3',
                  'asset_pattern': 'fluidd.zip',
                  'sha256':
                      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                  'install_path': '~/fluidd',
                },
                {
                  'id': 'mainsail',
                  'release_repo': 'mainsail-crew/mainsail',
                  'asset_pattern': 'mainsail.zip',
                  'sha256':
                      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
                  'install_path': '~/mainsail',
                },
              ],
              'default_choices': ['fluidd'],
              'allow_multiple': true,
            },
          },
        },
        ssh: ssh,
        upstream: upstream,
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);
      // Pretend the user picked fluidd on S105.
      await controller.setDecision('webui', ['fluidd']);
      controller.setSession(
        const SshSession(id: 'fake', host: 'h', port: 22, user: 'root'),
      );

      final events = <WizardEvent>[];
      final sub = controller.events.listen(events.add);
      await controller.startExecution();
      await sub.cancel();

      // The bug surfaced as a StepFailed; the fix means the step
      // completes cleanly.
      final failed = events.whereType<StepFailed>().toList();
      expect(
        failed,
        isEmpty,
        reason:
            'install_stack should not fail when '
            '{{stack.webui.selected}} is templated against a real '
            'webui decision (got: ${failed.map((e) => e.error).join(', ')})',
      );
      // Moonraker, fluidd (webui), and kiauh should all have been
      // attempted — fluidd via release fetch, the others via clone.
      final clones = ssh.runCalls.where((c) => c.contains('git clone'));
      expect(
        clones.any((c) => c.contains('moonraker')),
        isTrue,
        reason: 'moonraker should be cloned',
      );
      expect(
        clones.any((c) => c.contains('kiauh')),
        isTrue,
        reason: 'kiauh should be cloned',
      );
      // Fluidd uses a release-asset path, NOT git clone.
      expect(
        clones.any((c) => c.contains('fluidd')),
        isFalse,
        reason: 'fluidd should be release-fetched, not git-cloned',
      );
      expect(
        clones.every((c) => c.contains(" -- 'https://github.com/")),
        isTrue,
        reason: 'git clone must terminate option parsing before repo URLs',
      );
      expect(upstream.releaseCalls.single.tag, 'v1.34.3');
    });

    test('rejects option-looking git refs before cloning', () async {
      final ssh = FakeSsh();
      final controller = newController(
        profileJson: {
          ...baseProfileJson(
            stockKeepSteps: [
              {
                'id': 'install_stack',
                'kind': 'install_stack',
                'components': ['moonraker'],
              },
            ],
          ),
          'stack': {
            'moonraker': {
              'repo': 'https://github.com/Arksine/moonraker',
              'ref': '--upload-pack=touch-pwned',
              'install_path': '~/moonraker',
            },
          },
        },
        ssh: ssh,
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);
      controller.setSession(
        const SshSession(id: 'fake', host: 'h', port: 22, user: 'root'),
      );

      await expectLater(
        controller.startExecution(),
        throwsA(isA<StepExecutionException>()),
      );
      expect(ssh.runCalls.any((c) => c.contains('git clone')), isFalse);
      expect(ssh.runCalls.any((c) => c.contains('touch-pwned')), isFalse);
    });

    test('expands to multiple components when user picked Both', () async {
      final ssh = FakeSsh();
      final controller = newController(
        profileJson: {
          ...baseProfileJson(
            stockKeepSteps: [
              {
                'id': 'install_stack',
                'kind': 'install_stack',
                'components': ['{{stack.webui.selected}}'],
              },
            ],
          ),
          'stack': {
            'webui': {
              'choices': [
                {
                  'id': 'fluidd',
                  'release_repo': 'fluidd-core/fluidd',
                  'asset_pattern': 'fluidd.zip',
                  'sha256':
                      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                  'install_path': '~/fluidd',
                },
                {
                  'id': 'mainsail',
                  'release_repo': 'mainsail-crew/mainsail',
                  'asset_pattern': 'mainsail.zip',
                  'sha256':
                      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
                  'install_path': '~/mainsail',
                },
              ],
              'allow_multiple': true,
            },
          },
        },
        ssh: ssh,
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);
      // Both selected.
      await controller.setDecision('webui', ['fluidd', 'mainsail']);
      controller.setSession(
        const SshSession(id: 'fake', host: 'h', port: 22, user: 'root'),
      );

      final events = <WizardEvent>[];
      final sub = controller.events.listen(events.add);
      await controller.startExecution();
      await sub.cancel();
      expect(
        events.whereType<StepFailed>(),
        isEmpty,
        reason: 'install_stack should handle multi-select webui',
      );
    });

    test('expands to zero components when user picked Neither', () async {
      final ssh = FakeSsh();
      final controller = newController(
        profileJson: {
          ...baseProfileJson(
            stockKeepSteps: [
              {
                'id': 'install_stack',
                'kind': 'install_stack',
                'components': ['{{stack.webui.selected}}'],
              },
            ],
          ),
          'stack': {
            'webui': {
              'choices': [
                {
                  'id': 'fluidd',
                  'release_repo': 'fluidd-core/fluidd',
                  'asset_pattern': 'fluidd.zip',
                  'sha256':
                      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                  'install_path': '~/fluidd',
                },
              ],
              'allow_none': true,
            },
          },
        },
        ssh: ssh,
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);
      await controller.setDecision('webui', <String>[]);
      controller.setSession(
        const SshSession(id: 'fake', host: 'h', port: 22, user: 'root'),
      );

      final events = <WizardEvent>[];
      final sub = controller.events.listen(events.add);
      await controller.startExecution();
      await sub.cancel();
      expect(
        events.whereType<StepFailed>(),
        isEmpty,
        reason: 'install_stack should be a no-op when no webui chosen',
      );
    });
  });

  group('install_klipper_extras regression', () {
    // Regression: ssh.upload (raw SFTP) doesn't expand `~`, so
    // uploading CatchIP.py to `~/kalico/klippy/extras/CatchIP.py`
    // failed with "SftpStatusError: No such file (code 2)" while
    // the directory upload worked because it shell-routes via
    // mkdir -p + tar (and shell expands tildes).
    test('mkdir-p s the extras dir before single-file uploads', () async {
      final ssh = FakeSsh();
      final tmp = await Directory.systemTemp.createTemp('linkx-test');
      addTearDown(() async => tmp.delete(recursive: true));
      // Profile-local file the link_extras step will reference.
      await File(p.join(tmp.path, 'CatchIP.py')).writeAsString('# noop\n');

      final controller = WizardController(
        profiles: _PinnedLocationProfileService({
          ...baseProfileJson(
            stockKeepSteps: [
              {
                'id': 'install_klipper_extras',
                'kind': 'link_extras',
                'sources': ['./CatchIP.py'],
              },
            ],
          ),
          'firmware': {
            'choices': [
              {
                'id': 'kalico',
                'repo': 'https://github.com/KalicoCrew/kalico',
                'ref': 'main',
                'install_path': '~/kalico',
                'recommended': true,
              },
            ],
          },
        }, profileDirPath: tmp.path),
        ssh: ssh,
        flash: _StubFlashService(),
        discovery: _StubDiscoveryService(),
        moonraker: _StubMoonrakerService(),
        upstream: FakeUpstream(),
        security: FakeSecurity(),
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);
      await controller.setDecision('firmware', 'kalico');
      controller.setSession(
        const SshSession(id: 'fake', host: 'h', port: 22, user: 'root'),
      );

      final events = <WizardEvent>[];
      final sub = controller.events.listen(events.add);
      await controller.startExecution();
      await sub.cancel();

      expect(
        events.whereType<StepFailed>(),
        isEmpty,
        reason: 'link_extras should not fail on tilde-prefixed paths',
      );
      // Step should mkdir-p the extras dir BEFORE the single-file
      // upload — that's the fix for the SFTP "no such file" error.
      final mkdirCalls = ssh.runCalls.where(
        (c) => c.contains('mkdir -p') && c.contains('extras'),
      );
      expect(
        mkdirCalls,
        isNotEmpty,
        reason:
            'expected a `mkdir -p` for the extras directory before SFTP uploads',
      );
      // The SFTP upload should target a path with the `~/` stripped
      // (OpenSSH SFTP cwd defaults to home).
      final extraUpload = ssh.uploadCalls.firstWhere(
        (u) => u.remote.endsWith('CatchIP.py'),
        orElse: () => throw StateError('no CatchIP.py upload recorded'),
      );
      expect(
        extraUpload.remote.startsWith('~/'),
        isFalse,
        reason:
            'SFTP cannot expand tildes; remote path must not start with `~/`',
      );
    });
  });
}

// -----------------------------------------------------------------
// Minimal stub services.

class _StubProfileService implements ProfileService {
  _StubProfileService(this.profile);
  final PrinterProfile profile;
  @override
  Future<ProfileCacheEntry> ensureCached({
    required String profileId,
    String? ref,
    bool force = false,
  }) async => ProfileCacheEntry(
    profileId: profileId,
    ref: ref ?? 'main',
    localPath: '.',
    resolvedSha: 'deadbeef',
  );
  @override
  Future<PrinterProfile> load(ProfileCacheEntry cacheEntry) async => profile;
  @override
  Future<ProfileRegistry> fetchRegistry({bool force = false}) async =>
      const ProfileRegistry(entries: []);
}

/// ProfileService variant that reports a specific `localPath` so tests
/// can verify path-resolution rules (profile-local vs repo-root).
class _PinnedLocationProfileService implements ProfileService {
  _PinnedLocationProfileService(
    Map<String, dynamic> json, {
    required this.profileDirPath,
  }) : profile = PrinterProfile.fromJson(json);
  final PrinterProfile profile;
  final String profileDirPath;
  @override
  Future<ProfileCacheEntry> ensureCached({
    required String profileId,
    String? ref,
    bool force = false,
  }) async => ProfileCacheEntry(
    profileId: profileId,
    ref: ref ?? 'main',
    localPath: profileDirPath,
    resolvedSha: 'deadbeef',
  );
  @override
  Future<PrinterProfile> load(ProfileCacheEntry cacheEntry) async => profile;
  @override
  Future<ProfileRegistry> fetchRegistry({bool force = false}) async =>
      const ProfileRegistry(entries: []);
}

class _StubFlashService implements FlashService {
  _StubFlashService({
    this.safetyVerdict = const FlashSafetyVerdict(diskId: '', allowed: true),
  });

  final FlashSafetyVerdict safetyVerdict;
  final safetyChecks = <String>[];

  @override
  Future<List<DiskInfo>> listDisks() async => const [];
  @override
  Future<FlashSafetyVerdict> safetyCheck({required String diskId}) async {
    safetyChecks.add(diskId);
    return FlashSafetyVerdict(
      diskId: safetyVerdict.diskId.isEmpty ? diskId : safetyVerdict.diskId,
      allowed: safetyVerdict.allowed,
      blockingReasons: safetyVerdict.blockingReasons,
      warnings: safetyVerdict.warnings,
    );
  }

  @override
  Stream<FlashProgress> readImage({
    required String diskId,
    required String outputPath,
  }) => const Stream.empty();
  @override
  Future<String> sha256(String path) async => '';
  @override
  Stream<FlashProgress> writeImage({
    required String imagePath,
    required String diskId,
    required String confirmationToken,
    bool verifyAfterWrite = true,
  }) => const Stream.empty();
}

class _StubDiscoveryService implements DiscoveryService {
  @override
  Future<List<DiscoveredPrinter>> scanCidr({
    required String cidr,
    int port = 7125,
    Duration timeout = const Duration(seconds: 5),
  }) async => const [];
  @override
  Future<List<DiscoveredPrinter>> scanMdns({
    Duration timeout = const Duration(seconds: 5),
  }) async => const [];
  @override
  Future<bool> waitForSsh({
    required String host,
    int port = 22,
    Duration timeout = const Duration(minutes: 10),
  }) async => true;
}

class _StubMoonrakerService implements MoonrakerService {
  @override
  Future<KlippyInfo> info({required String host, int port = 7125}) async =>
      const KlippyInfo(
        state: 'ready',
        hostname: 'stub',
        softwareVersion: 'v0',
        klippyState: 'ready',
      );
  @override
  Future<bool> isPrinting({required String host, int port = 7125}) async =>
      false;
  @override
  Future<List<String>> listObjects({
    required String host,
    int port = 7125,
  }) async => const [];

  @override
  Future<String?> fetchConfigFile({
    required String host,
    int port = 7125,
    required String filename,
  }) async => null;
}

class FakeSshUpload {
  const FakeSshUpload({
    required this.local,
    required this.remote,
    required this.content,
    this.mode,
  });
  final String local;
  final String remote;
  // Captured at upload time so assertions survive the controller's
  // `finally` block that deletes the local staging file.
  final String content;
  final int? mode;
}

/// Per-call record so tests can assert on sudoPassword forwarding
/// without the "last call wins and gets overwritten" flakiness the
/// single-variable approach had.
class FakeSshRunCall {
  const FakeSshRunCall({required this.command, required this.sudoPassword});
  final String command;
  final String? sudoPassword;
}

class FakeSsh implements SshService {
  SshCommandResult nextRun = const SshCommandResult(
    stdout: '',
    stderr: '',
    exitCode: 0,
  );
  final runCalls = <String>[];
  final runDetails = <FakeSshRunCall>[];
  final uploadCalls = <FakeSshUpload>[];

  /// Legacy single-variable tracker. Kept for back-compat with tests
  /// that don't care about per-call granularity.
  String? lastSudoPassword;

  /// Run calls with bookkeeping commands filtered out. Tests care
  /// about install-step commands; the printer-state probe (a multi-
  /// line `#!/bin/sh` script that fires on every connect) and the
  /// run-state write/read commands (which target
  /// `~/.deckhand/run-state.json` per [docs/STEP-IDEMPOTENCY.md])
  /// are bookkeeping. The full set is still in [runCalls] for the
  /// few tests that explicitly assert on it.
  List<String> get steps => runCalls.where(_isInstallStep).toList();

  /// Same filter, but returns full run details (command + sudoPw).
  List<FakeSshRunCall> get stepDetails =>
      runDetails.where((d) => _isInstallStep(d.command)).toList();

  static bool _isInstallStep(String cmd) {
    if (cmd.startsWith('#!/bin/sh')) return false;
    if (cmd.contains('.deckhand/run-state.json')) return false;
    return true;
  }

  @override
  Future<SshSession> connect({
    required String host,
    int port = 22,
    required SshCredential credential,
    bool acceptHostKey = false,
    String? acceptedHostFingerprint,
  }) async => SshSession(id: 'fake', host: host, port: port, user: 'root');
  @override
  Future<SshSession> tryDefaults({
    required String host,
    int port = 22,
    required List<SshCredential> credentials,
    bool acceptHostKey = false,
    String? acceptedHostFingerprint,
  }) async => SshSession(id: 'fake', host: host, port: port, user: 'root');
  @override
  Future<SshCommandResult> run(
    SshSession session,
    String command, {
    Duration timeout = const Duration(seconds: 30),
    String? sudoPassword,
  }) async {
    runCalls.add(command);
    runDetails.add(
      FakeSshRunCall(command: command, sudoPassword: sudoPassword),
    );
    lastSudoPassword = sudoPassword;
    return nextRun;
  }

  @override
  Stream<String> runStream(SshSession session, String command) =>
      const Stream.empty();
  @override
  Stream<String> runStreamMerged(SshSession session, String command) =>
      const Stream.empty();
  @override
  Future<int> upload(
    SshSession session,
    String localPath,
    String remotePath, {
    int? mode,
  }) async {
    String content = '';
    try {
      content = await File(localPath).readAsString();
    } catch (_) {
      // Non-text or binary upload - fine for tests, just record empty.
    }
    uploadCalls.add(
      FakeSshUpload(
        local: localPath,
        remote: remotePath,
        content: content,
        mode: mode,
      ),
    );
    return 0;
  }

  @override
  Future<int> download(
    SshSession session,
    String remotePath,
    String localPath,
  ) async => 0;
  @override
  Future<Map<String, int>> duPaths(
    SshSession session,
    List<String> paths,
  ) async => {for (final p in paths) p: 0};
  @override
  Future<void> disconnect(SshSession session) async {}
}

/// Writes a minimal shell script to the test's temp dir and returns
/// its absolute path. Lets `_runScript` pass its file-exists gate.
Future<String> _stageLocalScript(String basename) async {
  final f = File(p.join(Directory.systemTemp.path, basename));
  await f.writeAsString('#!/bin/sh\nexit 0\n');
  return f.path;
}

class FakeUpstream implements UpstreamService {
  final _events = <OsDownloadProgress>[];
  final downloadCalls = <({String url, String destPath, String? sha256})>[];
  final releaseCalls =
      <
        ({
          String repoSlug,
          String assetPattern,
          String destPath,
          String expectedSha256,
          String? tag,
        })
      >[];
  void addDownloadEvent(OsDownloadProgress e) => _events.add(e);
  @override
  Future<UpstreamFetchResult> gitFetch({
    required String repoUrl,
    required String ref,
    required String destPath,
    int depth = 1,
  }) async => UpstreamFetchResult(localPath: destPath, resolvedRef: ref);
  @override
  Stream<OsDownloadProgress> osDownload({
    required String url,
    required String destPath,
    String? expectedSha256,
  }) async* {
    downloadCalls.add((url: url, destPath: destPath, sha256: expectedSha256));
    for (final e in _events) {
      yield e;
    }
  }

  @override
  Future<UpstreamFetchResult> releaseFetch({
    required String repoSlug,
    required String assetPattern,
    required String destPath,
    required String expectedSha256,
    String? tag,
  }) async {
    releaseCalls.add((
      repoSlug: repoSlug,
      assetPattern: assetPattern,
      destPath: destPath,
      expectedSha256: expectedSha256,
      tag: tag,
    ));
    return UpstreamFetchResult(
      localPath: destPath,
      resolvedRef: tag ?? 'latest',
    );
  }
}

class FakeElevatedHelperCall {
  FakeElevatedHelperCall({
    required this.imagePath,
    required this.diskId,
    required this.confirmationToken,
    required this.verifyAfterWrite,
    required this.expectedSha256,
  });
  final String imagePath;
  final String diskId;
  final String confirmationToken;
  final bool verifyAfterWrite;
  final String? expectedSha256;
}

class FakeElevatedHelper implements ElevatedHelperService {
  final _events = <FlashProgress>[];
  final calls = <FakeElevatedHelperCall>[];
  void addEvent(FlashProgress e) => _events.add(e);
  @override
  Stream<FlashProgress> writeImage({
    required String imagePath,
    required String diskId,
    required String confirmationToken,
    bool verifyAfterWrite = true,
    String? expectedSha256,
  }) async* {
    calls.add(
      FakeElevatedHelperCall(
        imagePath: imagePath,
        diskId: diskId,
        confirmationToken: confirmationToken,
        verifyAfterWrite: verifyAfterWrite,
        expectedSha256: expectedSha256,
      ),
    );
    for (final e in _events) {
      yield e;
    }
  }

  @override
  Stream<FlashProgress> readImage({
    required String diskId,
    required String outputPath,
    required String confirmationToken,
    int totalBytes = 0,
  }) async* {
    // No tests yet exercise the elevated read path; the stub mirrors
    // writeImage's empty-stream contract so adding readImage to the
    // interface didn't break compile and is ready for a future test.
    for (final e in _events) {
      yield e;
    }
  }
}

class FakeSecurity implements SecurityService {
  int _counter = 0;
  String lastTokenValue = '';
  @override
  Future<ConfirmationToken> issueConfirmationToken({
    required String operation,
    required String target,
    Duration ttl = const Duration(seconds: 60),
  }) async {
    _counter++;
    lastTokenValue = 'token-${_counter}abcdef0123456789';
    return ConfirmationToken(
      value: lastTokenValue,
      expiresAt: DateTime.now().add(ttl),
      operation: operation,
    );
  }

  final consumed = <String>[];
  @override
  bool consumeToken(String value, String operation) {
    consumed.add('$operation:$value');
    return true;
  }

  @override
  Future<bool> isHostAllowed(String host) async => true;
  @override
  Future<void> approveHost(String host) async {}

  @override
  Future<void> revokeHost(String host) async {}

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
  Future<List<String>> listApprovedHosts() async => const [];
  @override
  Future<String?> getGitHubToken() async => null;
  @override
  Future<void> setGitHubToken(String? token) async {}
  @override
  Future<Map<String, bool>> requestHostApprovals(List<String> hosts) async => {
    for (final h in hosts) h: true,
  };
  @override
  Stream<EgressEvent> get egressEvents => const Stream.empty();
  @override
  void recordEgress(EgressEvent event) {}
}

// -----------------------------------------------------------------
// Helpers

void unawaited(Future<void> f) {
  f.catchError((_) {});
}
