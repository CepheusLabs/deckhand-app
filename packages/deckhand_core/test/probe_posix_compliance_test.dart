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
            {
              'id': 'f',
              'paths': ['/tmp/f'],
            },
          ],
          'paths': [
            {'id': 'p', 'path': '/tmp/p', 'action': ''},
          ],
        },
        'stack': {
          'moonraker': {'repo': 'x', 'ref': 'y', 'install_path': '~/moonraker'},
        },
        'screens': [
          {'id': 's', 'install_path': '~/s', 'systemd_unit': 's.service'},
        ],
      });
      await probe.probe(
        session: const SshSession(id: 't', host: 'x', port: 22, user: 'u'),
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
      // to bash --posix. The test logs which shell validated so CI
      // output makes the coverage gap explicit - a green with dash
      // is stronger than a green with bash.
      final shells = ['dash', 'sh', 'bash'];
      final tried = <String>[];
      for (final shell in shells) {
        try {
          final shellPath = await _pathForPosixShell(tmp.path, shell);
          final res = await Process.run(
            shell,
            shell == 'bash' ? ['--posix', '-n', shellPath] : ['-n', shellPath],
          );
          tried.add(shell);
          if (res.exitCode == 0) {
            // ignore: avoid_print
            print(
              'probe script: `$shell -n` clean (tried: ${tried.join(",")})',
            );
            return;
          }
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
      markTestSkipped(
        'No POSIX shell on PATH for syntax check. '
        'Static checks above still apply; install `dash` for the '
        'strictest coverage.',
      );
    });

    test('dash -n passes when dash is installed on the host', () async {
      // Distinct test so CI can see explicitly when dash coverage
      // dropped off (vs. hiding the fallback behind the more lenient
      // multi-shell test). Skips cleanly when dash isn't available.
      try {
        final tmp = await File(
          '${Directory.systemTemp.path}/'
          'deckhand-probe-dash-${DateTime.now().microsecondsSinceEpoch}.sh',
        ).writeAsString(script);
        addTearDown(() async {
          try {
            await tmp.delete();
          } catch (_) {}
        });
        final shellPath = await _pathForPosixShell(tmp.path, 'dash');
        final res = await Process.run('dash', ['-n', shellPath]);
        if (res.exitCode != 0) {
          fail(
            'dash -n failed:\nstdout: ${res.stdout}\n'
            'stderr: ${res.stderr}',
          );
        }
      } on ProcessException {
        markTestSkipped('dash not on PATH - skipping strict POSIX check');
      }
    });
  });
}

Future<String> _pathForPosixShell(String path, String shell) async {
  if (!Platform.isWindows) return path;
  final candidates = <String>[];
  try {
    final res = await Process.run('cygpath', ['-u', path]);
    if (res.exitCode == 0) {
      final converted = (res.stdout as String).trim();
      if (converted.isNotEmpty) candidates.add(converted);
    }
  } on ProcessException {
    // Fall back below; Git Bash/MSYS accept /c/... paths.
  }

  final normalized = path.replaceAll('\\', '/');
  final drive = RegExp(r'^([A-Za-z]):/(.*)$').firstMatch(normalized);
  if (drive == null) return normalized;
  final letter = drive.group(1)!.toLowerCase();
  final rest = drive.group(2)!;
  if (shell == 'bash' && await _isWindowsWslBash()) {
    return '/mnt/$letter/$rest';
  }
  candidates
    ..add('/$letter/$rest')
    ..add('/mnt/$letter/$rest');

  for (final candidate in candidates.toSet()) {
    try {
      final args = shell == 'bash'
          ? ['--posix', '-c', 'test -f "\$DECKHAND_PROBE_PATH"']
          : ['-c', 'test -f "\$DECKHAND_PROBE_PATH"'];
      final res = await Process.run(
        shell,
        args,
        environment: {'DECKHAND_PROBE_PATH': candidate},
      );
      if (res.exitCode == 0) return candidate;
    } on ProcessException {
      break;
    }
  }
  return candidates.first;
}

Future<bool> _isWindowsWslBash() async {
  try {
    final res = await Process.run('where.exe', ['bash']);
    if (res.exitCode != 0) return false;
    final first = (res.stdout as String).split('\n').first.trim().toLowerCase();
    return first.endsWith(r'\system32\bash.exe');
  } on ProcessException {
    return false;
  }
}

class _CapturingSsh implements SshService {
  String? captured;
  @override
  Future<SshSession> connect({
    required String host,
    int port = 22,
    required SshCredential credential,
    bool acceptHostKey = false,
    String? acceptedHostFingerprint,
  }) async => SshSession(id: 'x', host: host, port: port, user: 'u');
  @override
  Future<SshSession> tryDefaults({
    required String host,
    int port = 22,
    required List<SshCredential> credentials,
    bool acceptHostKey = false,
    String? acceptedHostFingerprint,
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
  Stream<String> runStreamMerged(SshSession session, String command) =>
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
  Future<Map<String, int>> duPaths(
    SshSession session,
    List<String> paths,
  ) async => {for (final p in paths) p: 0};
  @override
  Future<void> disconnect(SshSession session) async {}
}
