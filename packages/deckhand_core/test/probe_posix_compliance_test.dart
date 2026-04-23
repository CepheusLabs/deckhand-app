import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// Static-analysis test for the probe shell script. It can't run the
/// script (we'd need an SSH session) but it can verify the generated
/// source is free of bash-isms that would break on busybox / dash,
/// and when `bash --posix` / `dash` is available on the host it does
/// a real syntax check with `-n` so obvious mistakes fail CI.
///
/// Runs against [PrinterStateProbe]'s actual script generator by
/// wiring a minimal SSH stub that captures the generated command.
void main() {
  group('Probe script POSIX compliance', () {
    late String script;

    setUpAll(() async {
      final ssh = _CapturingSsh();
      final probe = PrinterStateProbe(ssh: ssh);
      final profile = PrinterProfile.fromJson({
        'profile_id': 'compliance',
        'stock_os': {
          'services': [
            {
              'id': 'svc',
              'systemd_unit': 'svc.service',
              'process_pattern': 'svc',
              'launched_by': {'kind': 'script', 'path': '/usr/bin/svc'},
            },
          ],
          'files': [
            {'id': 'f', 'paths': ['/tmp/f']},
          ],
          'paths': [
            {'id': 'p', 'path': '/tmp/p', 'action': ''},
          ],
        },
        'stack': {
          'moonraker': {
            'repo': 'x', 'ref': 'y', 'install_path': '~/moonraker',
          },
        },
        'screens': [
          {
            'id': 's',
            'install_path': '~/s',
            'systemd_unit': 's.service',
          },
        ],
      });
      await probe.probe(
        session: SshSession(id: 't', host: 'x', port: 22, user: 'u'),
        profile: profile,
      );
      script = ssh.captured!;
    });

    test('no bash-only [[ ... ]] tests', () {
      // `[[ ]]` only works in bash/zsh/ksh; busybox ash + dash
      // require `[ ]` (the POSIX `test` builtin).
      expect(script.contains('[['), isFalse);
      expect(script.contains(']]'), isFalse);
    });

    test('no here-string <<<', () {
      // `<<<` is bash-only.
      expect(script.contains('<<<'), isFalse);
    });

    test('no bash-function syntax `function name()`', () {
      // POSIX sh requires `name() { ... }`, not `function name() {...}`.
      expect(RegExp(r'\bfunction\s+\w+\s*\(').hasMatch(script), isFalse);
    });

    test('no case modifiers like \${var^^} or \${var,,}', () {
      expect(script.contains(r'^^}'), isFalse);
      expect(script.contains(r',,}'), isFalse);
    });

    test('no ANSI-C \$\'...\' quoting', () {
      // `$'\n'` is bash. POSIX uses `printf '\n'` or literal newlines.
      // Our parser already expects `\t` separators; verify we emit
      // literal tab characters via printf, not $'\t'.
      expect(RegExp(r"\$'[^']").hasMatch(script), isFalse);
    });

    test('no sed -E (extended regex); busybox sed needs BRE', () {
      // Our backup-discovery `sed` has to stay POSIX-BRE because old
      // busybox builds don't support -E.
      expect(script.contains('sed -E'), isFalse);
      expect(script.contains('sed --regexp-extended'), isFalse);
    });

    test('no bash arrays', () {
      // `arr=(a b)` / `${arr[@]}` are bash-only.
      expect(RegExp(r'\$\{[A-Za-z_]\w*\[@\]\}').hasMatch(script), isFalse);
    });

    test('real syntax check via `sh -n` when available', () async {
      // Every POSIX shell supports -n (parse-only). Write the script
      // to a temp file and have the host shell validate it.
      final tmp = await File(
        '${Directory.systemTemp.path}/'
        'deckhand-probe-syntax-${DateTime.now().microsecondsSinceEpoch}.sh',
      ).writeAsString(script);
      addTearDown(() async {
        try {
          await tmp.delete();
        } catch (_) {}
      });
      // Try dash first (strictest POSIX), fall back to sh, fall back
      // to bash --posix. If none are present on the host, skip.
      final shells = ['dash', 'sh', 'bash'];
      for (final shell in shells) {
        try {
          final res = await Process.run(
            shell,
            shell == 'bash'
                ? ['--posix', '-n', tmp.path]
                : ['-n', tmp.path],
          );
          if (res.exitCode == 0) return; // green
          fail(
            'Probe script failed `$shell -n`:\n'
            'stdout: ${res.stdout}\nstderr: ${res.stderr}',
          );
        } on ProcessException {
          continue; // shell not on PATH, try next
        }
      }
      // If we got here, no POSIX shell was available on the runner.
      // That's fine on some CI; the static-analysis tests above cover
      // the common cases. Don't fail on missing tooling.
      markTestSkipped('No POSIX shell on PATH for syntax check');
    });
  });
}

class _CapturingSsh implements SshService {
  String? captured;
  @override
  Future<SshSession> connect({
    required String host,
    int port = 22,
    required SshCredential credential,
    bool acceptHostKey = false,
  }) async => SshSession(id: 'x', host: host, port: port, user: 'u');
  @override
  Future<SshSession> tryDefaults({
    required String host,
    int port = 22,
    required List<SshCredential> credentials,
  }) async => SshSession(id: 'x', host: host, port: port, user: 'u');
  @override
  Future<SshCommandResult> run(
    SshSession session,
    String command, {
    Duration timeout = const Duration(seconds: 30),
    String? sudoPassword,
  }) async {
    captured = command;
    return const SshCommandResult(stdout: '', stderr: '', exitCode: 0);
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
  }) async => 0;
  @override
  Future<int> download(
    SshSession session,
    String remotePath,
    String localPath,
  ) async => 0;
  @override
  Future<void> disconnect(SshSession session) async {}
}
