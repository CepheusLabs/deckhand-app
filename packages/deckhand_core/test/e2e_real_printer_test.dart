@Tags(['e2e'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// End-to-end restore test against a real printer over SSH. Gated by
/// the `e2e` tag so CI + the default `flutter test` run skip it
/// unless explicitly asked via
/// `flutter test --tags e2e --dart-define=DECKHAND_E2E_HOST=...`.
///
/// The test exercises the ACTUAL shell pipeline Deckhand emits (not
/// a FakeSsh mirror): seed a root-owned file, snapshot it, mutate the
/// live file, restore from the snapshot, assert SHA-exact roundtrip.
/// Uses `install` for the seed because that's how production
/// write_file stages its drops.
///
/// Pre-requisites for running:
///   - SSH reachable at $DECKHAND_E2E_HOST (default 192.168.0.41)
///   - SSH key auth OR password via $DECKHAND_E2E_PASSWORD
///   - `openssh ssh` on PATH
///   - The remote user is in sudoers
///
/// Leaves no state on the printer: uses an addTearDown to rm the
/// seeded files even if the test aborts mid-way.
void main() {
  final host = _env('DECKHAND_E2E_HOST', 'mks@192.168.0.41');
  final password = _env('DECKHAND_E2E_PASSWORD', 'makerbase');

  bool canReach = false;
  setUpAll(() async {
    // Quick connectivity check - if SSH won't come up, skip instead
    // of hammering red failures on a dev machine with no Arco.
    final ping = await Process.run(
      'ssh',
      [
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=3',
        host,
        'true',
      ],
    );
    canReach = ping.exitCode == 0;
  });

  test(
    'root-owned write_file + restore preserves SHA byte-exact',
    () async {
      if (!canReach) {
        markTestSkipped(
          'SSH to $host unavailable - set DECKHAND_E2E_HOST or run from '
          'a box on the printer LAN. Skipping E2E hardware test.',
        );
        return;
      }

      final ts = DateTime.now().microsecondsSinceEpoch;
      final target = '/etc/deckhand-e2e-test-$ts.conf';
      final backup = '$target.deckhand-pre-test-printer-$ts';
      // Register teardown BEFORE the test body does its first remote
      // write so a mid-test crash still cleans up.
      addTearDown(() async {
        await _ssh(host, password,
            'sudo -S rm -f $target $backup ${backup}.meta.json');
      });

      // Seed the file with non-trivial content via a /tmp stage +
      // sudo install - the same pattern write_file uses.
      const seed = 'ROOT_TEST_SEED_nontrivial\nline2\n';
      final seedSha = _sha256(seed);
      await _sshWithStdin(host, password,
          'tee /tmp/deckhand-e2e-seed-$ts > /dev/null', stdin: seed);
      await _ssh(host, password,
          'sudo -S install -m 0644 -o root -g root '
              '/tmp/deckhand-e2e-seed-$ts $target && '
              'rm -f /tmp/deckhand-e2e-seed-$ts');

      final remoteSeed = await _ssh(host, password,
          'sudo -S sha256sum $target');
      expect(
        remoteSeed.split(' ').first,
        seedSha,
        reason: 'seed must land byte-exact on the printer before '
            'the restore flow runs',
      );

      // Snapshot (what _runWriteFile.backup emits).
      final snapOut = await _ssh(
        host,
        password,
        'sudo -S sh -c \'if [ ! -e $target ]; then echo NOOP; '
        'elif ! ( touch "\$(dirname $target)/.deckhand-wtest-$ts" 2>/dev/null '
        '&& rm -f "\$(dirname $target)/.deckhand-wtest-$ts" ); then '
        'echo RO_FS; '
        'else cp -p $target $backup && echo CREATED; fi\'',
      );
      expect(snapOut.trim(), 'CREATED',
          reason: 'the auto-backup sentinel must fire CREATED on a '
              'writable system path');

      // Mutate the live file (simulating whatever write_file does
      // next).
      await _ssh(host, password,
          'sudo -S sh -c "echo CLOBBERED_$ts > $target"');
      final mutated = await _ssh(host, password, 'sudo -S sha256sum $target');
      expect(mutated.split(' ').first, isNot(seedSha),
          reason: 'sanity: mutation must actually change the file');

      // Restore via the same shell pipeline restoreBackup emits.
      await _ssh(host, password,
          'sudo -S cp -p $backup $target && '
          'sudo -S chown --reference=$backup $target 2>/dev/null || true');
      final restored = await _ssh(host, password,
          'sudo -S sha256sum $target');
      expect(
        restored.split(' ').first,
        seedSha,
        reason:
            'restore must round-trip the file SHA-exact - this is the '
            'invariant the whole backup system exists to guarantee',
      );

      // Ownership + mode survived cp -p.
      final ownMode = await _ssh(host, password,
          'sudo -S stat -c "%U:%G %a" $target');
      expect(ownMode.trim(), 'root:root 644',
          reason: 'cp -p must preserve owner + mode after restore');
    },
    tags: ['e2e'],
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

String _env(String key, String fallback) =>
    Platform.environment[key] ?? fallback;

String _sha256(String s) {
  // Use the same sha256 routine the printer runs; delegates to
  // `sha256sum` via `printf ... | sha256sum` so this side of the
  // test and the remote agree on bytes. Avoid the crypto package
  // dep for a test-only helper.
  final proc = Process.runSync(
    'sh',
    ['-c', "printf %s ${_shellQuote(s)} | sha256sum | cut -d' ' -f1"],
  );
  return (proc.stdout as String).trim();
}

String _shellQuote(String s) =>
    "'${s.replaceAll("'", r"'\''")}'";

Future<String> _ssh(String hostSpec, String password, String cmd) async {
  final p = await Process.start(
    'ssh',
    ['-o', 'BatchMode=no', hostSpec, 'echo $password | $cmd'],
  );
  final out = StringBuffer();
  await for (final line
      in p.stdout.transform(const SystemEncoding().decoder)) {
    out.write(line);
  }
  await p.stderr.drain<void>();
  final code = await p.exitCode;
  if (code != 0) {
    throw Exception('ssh $hostSpec $cmd exited $code');
  }
  return out.toString();
}

Future<void> _sshWithStdin(
  String hostSpec,
  String password,
  String cmd, {
  required String stdin,
}) async {
  final p = await Process.start(
    'ssh',
    ['-o', 'BatchMode=no', hostSpec, cmd],
  );
  p.stdin.write(stdin);
  await p.stdin.close();
  await p.stdout.drain<void>();
  await p.stderr.drain<void>();
  final code = await p.exitCode;
  if (code != 0) throw Exception('ssh exit $code');
}
