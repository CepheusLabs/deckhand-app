import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// End-to-end tests for [WizardController] step execution. We stub every
/// service so the controller runs in-process without hitting the
/// filesystem, network, or SSH.
void main() {
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
          'sha256': 'abc123',
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
      'stock_keep': {
        'enabled': true,
        'steps': stockKeepSteps ?? const [],
      },
      'fresh_flash': {
        'enabled': true,
        'steps': freshFlashSteps ?? const [],
      },
    },
  };

  WizardController newController({
    required Map<String, dynamic> profileJson,
    FakeSsh? ssh,
    FakeUpstream? upstream,
    FakeElevatedHelper? helper,
    FakeSecurity? security,
  }) {
    final profile = PrinterProfile.fromJson(profileJson);
    return WizardController(
      profiles: _StubProfileService(profile),
      ssh: ssh ?? FakeSsh(),
      flash: _StubFlashService(),
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

    test(
      'emits UserInputRequired when no prior decision was made',
      () async {
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
      },
    );
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
              sha256: 'abc123',
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
        expect(controller.state.decisions['flash.image_sha256'], 'abc123');
        expect(progress, hasLength(greaterThanOrEqualTo(2)));
        expect(progress.last.percent, 1.0);
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
        expect(helper.calls.first.diskId, 'PhysicalDrive3');
        expect(helper.calls.first.imagePath, 'C:/tmp/test.img');
        expect(helper.calls.first.verifyAfterWrite, true);
        expect(helper.calls.first.expectedSha256, 'abc123');
        expect(helper.calls.first.confirmationToken, security.lastTokenValue);
      },
    );
  });

  group('WizardController script step kind', () {
    test('uploads + executes script via ssh, surfaces failures', () async {
      final ssh = FakeSsh()..nextRun = const SshCommandResult(
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

    test('resolves shared/ paths against the repo root, not profile dir',
        () async {
      // Simulate the real cache layout: <tmp>/<repo>/printers/<id>/
      final repoRoot = await Directory.systemTemp.createTemp('deckhand-repo-');
      final sharedDir = Directory(p.join(repoRoot.path, 'shared', 'scripts'));
      await sharedDir.create(recursive: true);
      final scriptPath = p.join(sharedDir.path, 'build-python.sh');
      await File(scriptPath).writeAsString('#!/bin/sh\nexit 0\n');

      final profileDir =
          Directory(p.join(repoRoot.path, 'printers', 'test-printer'));
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
        ssh.runCalls.any((c) => c.contains('bash /tmp/deckhand-build-python.sh')),
        isTrue,
      );

      await repoRoot.delete(recursive: true);
    });

    test(
      'script default: sudo:false + askpass helper staged; internal sudos work',
      () async {
        final tmp = await _stageLocalScript('noop.sh');
        final ssh = FakeSsh()
          ..nextRun = const SshCommandResult(
            stdout: 'done', stderr: '', exitCode: 0,
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
        final uploadedTargets =
            ssh.uploadCalls.map((u) => u.remote).toList();
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
          (c) => c.contains('bash /tmp/deckhand-noop.sh'),
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
            stdout: '', stderr: '', exitCode: 0,
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
        final runCmd = ssh.runCalls.firstWhere(
          (c) => c.contains('bash /tmp/deckhand-rebuild.sh'),
        );
        expect(runCmd, contains('SUDO_ASKPASS=\'/tmp/deckhand-askpass-'));
        expect(runCmd, contains('sudo -A -E bash /tmp/deckhand-rebuild.sh'));
        expect(ssh.lastSudoPassword, isNull);
      },
    );

    test('script with askpass:false skips helper staging entirely', () async {
      final tmp = await _stageLocalScript('pure.sh');
      final ssh = FakeSsh()
        ..nextRun = const SshCommandResult(
          stdout: '', stderr: '', exitCode: 0,
        );
      final controller = newController(
        profileJson: baseProfileJson(
          stockKeepSteps: [
            {
              'id': 'sh',
              'kind': 'script',
              'path': tmp,
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

      // Only the script itself is uploaded, nothing else.
      expect(ssh.uploadCalls, hasLength(1));
      expect(ssh.uploadCalls.single.remote, '/tmp/deckhand-pure.sh');
      expect(ssh.steps.single, 'bash /tmp/deckhand-pure.sh');
    });

    test(
      'script with sudo:true AND no askpass uses sudoPassword forwarding',
      () async {
        final tmp = await _stageLocalScript('rebuild.sh');
        final ssh = FakeSsh()
          ..nextRun = const SshCommandResult(
            stdout: '', stderr: '', exitCode: 0,
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
        // the password via the sudoPassword parameter.
        expect(ssh.steps.single, startsWith('-E bash /tmp/deckhand-rebuild.sh'));
        expect(ssh.lastSudoPassword, 'root');
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

      expect(ssh.steps.single, 'systemctl status klipper');
      expect(ssh.lastSudoPassword, 'root');
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

      expect(ssh.steps.single, 'ls /home/mks');
      expect(ssh.lastSudoPassword, isNull);
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
      // sudo-stripped by _runSsh).
      expect(ssh.uploadCalls, hasLength(1));
      expect(ssh.uploadCalls.single.remote, startsWith('/tmp/deckhand-write-'));
      expect(ssh.steps.single, startsWith('install -m 644 '));
      expect(ssh.steps.single, contains("-o 'root' "));
      expect(ssh.steps.single, contains('/etc/apt/sources.list'));
      expect(ssh.lastSudoPassword, 'root');
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
      expect(ssh.steps.single, startsWith('mv '));
      expect(ssh.steps.single, contains('chmod 755'));
      expect(ssh.lastSudoPassword, isNull);
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
      final backup = ssh.steps.firstWhere(
        (c) => c.contains('cp -p'),
      );
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
      // Metadata sidecar gets written alongside the backup.
      expect(backup, contains('.meta.json'));
      expect(backup, contains('"profile_id": "test-printer"'));
    });

    test('write_file require_path gates the write on a live precondition',
        () async {
      final ssh = FakeSsh()
        // First [ -e ... ] check returns 'n' to indicate the required
        // path is missing.
        ..nextRun = const SshCommandResult(
          stdout: 'n', stderr: '', exitCode: 0,
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
    });
  });

  group('WizardController.restoreBackup / deleteBackup / pruneBackups', () {
    test('restoreBackup routed through _runSsh, sudo-stripped for system path',
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
    });

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
          (d) => d.command.contains('cp -p') &&
              d.command.contains('/etc/apt/sources.list'),
        );
        expect(
          cpCall.sudoPassword,
          'root',
          reason: 'Must forward the cached SSH password to sudo via -S '
              'when the original path is root-owned.',
        );
      },
    );

    test('restoreBackup stays unprivileged for paths under the user home',
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
    });

    test('deleteBackup removes both the backup file AND its sidecar',
        () async {
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
      expect(
        rms.any((c) => c.contains('/etc/apt/sources.list')),
        isTrue,
      );
      expect(
        rms.any((c) => c.contains('/etc/default/grub')),
        isTrue,
      );
      expect(
        rms.any((c) => c.contains('/home/root/printer.cfg')),
        isTrue,
      );
      expect(
        rms.any((c) => c.contains('/etc/hostname')),
        isFalse,
        reason: 'Fresh backup must survive the prune',
      );
      // Sidecars included in the prune.
      expect(
        rms.any((c) => c.contains('.meta.json')),
        isTrue,
      );
    });

    test('pruneBackups keepLatestPerTarget spares the newest per target',
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
    });

    test('pruneBackups with nothing to do returns 0 and does not touch ssh',
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
    });

    test('readBackupContent runs binary-probe then text-read via sudo',
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
    });

    test('readBackupContent returns a marker string for binary backups',
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
    });
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
      expect(relevant.any((c) => c.startsWith('mkdir -p ') &&
          c.contains('/home/root/printer_data/config')), isTrue);
      expect(relevant.any((c) => c.startsWith('mv ') &&
          c.contains('/deckhand.json')), isTrue);

      // The payload must contain the profile id + schema version.
      final uploadedContent = ssh.uploadCalls.single.content;
      expect(uploadedContent, contains('"profile_id": "test-printer"'));
      expect(uploadedContent, contains('"deckhand_schema": 1'));
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
  @override
  Future<List<DiskInfo>> listDisks() async => const [];
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
  const FakeSshRunCall({
    required this.command,
    required this.sudoPassword,
  });
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

  /// Run calls with the background state-probe filtered out. The probe
  /// fires automatically on connect and muddies per-test assertions;
  /// every test cares about the FOREGROUND commands its step
  /// generated, not the probe's multi-line shell script.
  List<String> get steps =>
      runCalls.where((c) => !c.startsWith('#!/bin/sh')).toList();

  /// Same filter, but returns full run details (command + sudoPw).
  List<FakeSshRunCall> get stepDetails => runDetails
      .where((d) => !d.command.startsWith('#!/bin/sh'))
      .toList();

  @override
  Future<SshSession> connect({
    required String host,
    int port = 22,
    required SshCredential credential,
    bool acceptHostKey = false,
  }) async => SshSession(id: 'fake', host: host, port: port, user: 'root');
  @override
  Future<SshSession> tryDefaults({
    required String host,
    int port = 22,
    required List<SshCredential> credentials,
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
    uploadCalls.add(FakeSshUpload(
      local: localPath,
      remote: remotePath,
      content: content,
      mode: mode,
    ));
    return 0;
  }

  @override
  Future<int> download(
    SshSession session,
    String remotePath,
    String localPath,
  ) async => 0;
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
    for (final e in _events) {
      yield e;
    }
  }
  @override
  Future<UpstreamFetchResult> releaseFetch({
    required String repoSlug,
    required String assetPattern,
    required String destPath,
    String? tag,
  }) async => UpstreamFetchResult(
    localPath: destPath,
    resolvedRef: tag ?? 'latest',
  );
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
  @override
  Future<bool> isHostAllowed(String host) async => true;
  @override
  Future<void> pinHostFingerprint({
    required String host,
    required String fingerprint,
  }) async {}
  @override
  Future<String?> pinnedHostFingerprint(String host) async => null;
  @override
  Future<Map<String, bool>> requestHostApprovals(List<String> hosts) async => {
    for (final h in hosts) h: true,
  };
}

// -----------------------------------------------------------------
// Helpers

void unawaited(Future<void> f) {
  f.catchError((_) {});
}
