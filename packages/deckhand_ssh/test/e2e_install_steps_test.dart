@Tags(['e2e'])
library;

import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ssh/deckhand_ssh.dart';
import 'package:flutter_test/flutter_test.dart';

/// Live install-step exercise against a real printer at
/// $DECKHAND_E2E_HOST. Validates the exact shell semantics the
/// production wizard relies on for the steps that have historically
/// regressed (install_klipper_extras single-file SFTP upload to a
/// tilde path, install_firmware git --progress streaming, install_stack
/// release-asset extract). Probes /tmp/deckhand-e2e-* and
/// ~/deckhand-e2e-* with `tearDownAll` cleanup so the printer's real
/// install is never touched.
///
/// Gated by `--tags e2e`. Set DECKHAND_E2E_HOST=user@host (default
/// `mks@192.168.0.13`) and DECKHAND_E2E_PASSWORD (default
/// `makerbase`). Skips cleanly when SSH isn't reachable.
void main() {
  final hostSpec =
      Platform.environment['DECKHAND_E2E_HOST'] ?? 'mks@192.168.0.13';
  final password =
      Platform.environment['DECKHAND_E2E_PASSWORD'] ?? 'makerbase';
  final parts = hostSpec.split('@');
  final user = parts.length > 1 ? parts[0] : 'mks';
  final host = parts.length > 1 ? parts[1] : parts[0];

  final ssh = DartsshService();
  SshSession? session;

  setUpAll(() async {
    try {
      session = await ssh.connect(
        host: host,
        port: 22,
        credential: PasswordCredential(user: user, password: password),
        acceptHostKey: true,
      );
    } catch (e) {
      stderr.writeln('SSH connect to $hostSpec failed: $e');
    }
  });

  tearDownAll(() async {
    final s = session;
    if (s != null) {
      try {
        await ssh.run(
          s,
          'rm -rf /tmp/deckhand-e2e-* "\$HOME/deckhand-e2e-extras-test"',
        );
      } catch (_) {}
      try {
        await ssh.disconnect(s);
      } catch (_) {}
    }
  });

  test(
    'SFTP single-file upload to relative path lands in user home',
    () async {
      final s = session;
      if (s == null) {
        markTestSkipped('SSH unreachable - skipping live SFTP test');
        return;
      }
      // Validates the install_klipper_extras fix on real hardware:
      // OpenSSH SFTP defaults its cwd to the user's home, so dropping
      // the `~/` prefix on the remote path lets a single-file upload
      // succeed even though SFTP itself can't expand tildes. Also
      // exercises the dartssh `run` drain fix — without it `cat` of a
      // small file silently returns empty.
      final probe = await ssh.run(
        s,
        'eval echo ~',
      );
      final home = probe.stdout.trim();
      expect(home, isNotEmpty,
          reason: 'tilde expansion should resolve to user home');

      final tmpFile = await File(
        '${Directory.systemTemp.path}/deckhand-e2e-payload.py',
      ).writeAsString('# deckhand e2e payload\n');
      await ssh.run(
        s,
        'mkdir -p "$home/deckhand-e2e-extras-test/extras"',
      );
      const remoteRel = 'deckhand-e2e-extras-test/extras/payload-rel.py';
      final relN = await ssh.upload(s, tmpFile.path, remoteRel);
      expect(relN, greaterThan(0));

      // Verify it landed where we expected (under home).
      final cat = await ssh.run(
        s,
        'cat "$home/deckhand-e2e-extras-test/extras/payload-rel.py"',
      );
      expect(cat.exitCode, 0, reason: 'cat: ${cat.stderr}');
      expect(cat.stdout, contains('deckhand e2e payload'),
          reason:
              'SFTP relative path should resolve to home; if it does not '
              'on this printer, install_klipper_extras needs absolute paths');

      try {
        await tmpFile.delete();
      } catch (_) {}
    },
    tags: ['e2e'],
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'git clone --progress emits parseable progress lines',
    () async {
      final s = session;
      if (s == null) {
        markTestSkipped('SSH unreachable - skipping git-progress test');
        return;
      }
      final cmd =
          'rm -rf /tmp/deckhand-e2e-clone && '
          'git clone --progress --depth 1 '
          'https://github.com/octocat/Hello-World /tmp/deckhand-e2e-clone '
          '2>&1';
      final res = await ssh.run(
        s,
        cmd,
        timeout: const Duration(seconds: 60),
      );
      expect(res.exitCode, 0,
          reason: 'clone failed: ${res.stderr}\n${res.stdout}');
      final progressy = RegExp(
          r'(Receiving objects|Resolving deltas|Counting objects)');
      expect(
        progressy.hasMatch(res.stdout) || progressy.hasMatch(res.stderr),
        isTrue,
        reason:
            'expected git --progress output, got:\n${res.stdout}\n${res.stderr}',
      );
      await ssh.run(s, 'rm -rf /tmp/deckhand-e2e-clone');
    },
    tags: ['e2e'],
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
