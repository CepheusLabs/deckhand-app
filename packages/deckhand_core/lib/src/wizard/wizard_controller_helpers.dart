// Cross-cutting helpers split out of wizard_controller.dart so the
// main controller stays under the project's 800-line ceiling. All of
// these are top-level private helpers that take the controller as
// their first argument; they share WizardController's library-private
// scope because this file is `part of 'wizard_controller.dart'`.
part of 'wizard_controller.dart';

/// Runs [command] over SSH. If [command] starts with `sudo`,
/// `/usr/bin/sudo`, or `/bin/sudo` and we have a cached password
/// for the session, strips that sudo word and delegates to
/// [SshService.run] with `sudoPassword`. The SshService then wraps
/// in `echo <pw> | sudo -S ...`, so sudo reads the password on stdin
/// without needing a pty.
///
/// Commands that START with a `KEY=value` env assignment (e.g. the
/// askpass-wrapped `SUDO_ASKPASS=... sudo -A -E ...` form built by
/// `_runScript`) are intentionally NOT stripped: we already routed
/// auth through askpass, and combining `-S` with `-A` varies by sudo
/// version. Anything without a sudo at position zero runs as-is.
Future<SshCommandResult> _runSshImpl(
  WizardController c,
  String command, {
  Duration timeout = const Duration(seconds: 30),
}) {
  final s = c._requireSession();
  final stripped = _stripSudoPrefix(command);
  if (stripped != null && c._sshPassword != null) {
    return c.ssh.run(
      s,
      stripped,
      timeout: timeout,
      sudoPassword: c._sshPassword,
    );
  }
  return c.ssh.run(s, command, timeout: timeout);
}

/// Returns the command with the `sudo` token removed if [command]
/// begins with sudo / /usr/bin/sudo / /bin/sudo. Returns null for
/// everything else (subshells, env-prefixed commands, commands that
/// start with any other word).
///
/// Compound commands (`sudo X && rm Y`, `sudo X | grep Y`) are
/// matched - the outer `sudo -S` replacement still produces the
/// right behaviour because we only authenticate sudo and let the
/// rest of the shell line run unchanged.
String? _stripSudoPrefix(String command) {
  final m = RegExp(
    r'^(?<sudo>sudo|/usr/bin/sudo|/bin/sudo)(?:\s+(?<rest>.*))?$',
  ).firstMatch(command);
  if (m == null) return null;
  return m.namedGroup('rest') ?? '';
}

/// Turn a profile-declared relative path into an absolute local path.
///
/// Three conventions, in priority order:
///   - absolute (`/etc/foo`): returned as-is.
///   - profile-local (`./scripts/foo.sh`): resolved against the
///     profile's directory (where profile.yaml lives).
///   - repo-root-relative (`shared/scripts/build-python.sh`): resolved
///     against the deckhand-profiles repo root. Profile dirs live at
///     `<root>/printers/<id>/`, so the repo root is two levels up.
///
/// Bare paths without a prefix default to profile-local (the legacy
/// behaviour) - add `./` for new profiles to make the intent loud.
String _resolveProfilePathImpl(WizardController c, String ref) {
  final profileDir = c._profileCache?.localPath ?? '.';
  if (ref.startsWith('/')) return ref;
  if (ref.startsWith('./')) return p.join(profileDir, ref.substring(2));
  // `shared/` is the repo-level tree of scripts and templates reused
  // across printers. Resolve it against the repo root.
  if (ref.startsWith('shared/') || ref.startsWith('shared\\')) {
    final repoRoot = p.dirname(p.dirname(profileDir));
    return p.join(repoRoot, ref);
  }
  return p.join(profileDir, ref);
}

Future<void> _uploadDirImpl(
  WizardController c,
  String localDir,
  String remote,
) async {
  final s = c._requireSession();
  final tmpTar = p.join(
    Directory.systemTemp.path,
    'deckhand-upload-${DateTime.now().millisecondsSinceEpoch}.tar',
  );
  final result = await Process.run('tar', [
    '-cf',
    tmpTar,
    '-C',
    p.dirname(localDir),
    '--',
    p.basename(localDir),
  ]);
  if (result.exitCode != 0) {
    throw StepExecutionException('local tar failed: ${result.stderr}');
  }
  try {
    final remoteTar =
        '/tmp/deckhand-upload-${DateTime.now().millisecondsSinceEpoch}.tar';
    await c.ssh.upload(s, tmpTar, remoteTar);
    // Profile-supplied remote path must go through shellPathEscape;
    // double-quote interpolation lets a path with an embedded
    // backtick or "$(...)" break out of the quoted string. The
    // generated remoteTar is shellSingleQuote because it has no
    // tilde expansion to preserve.
    final qRemote = shellPathEscape(remote);
    final qRemoteTar = shellSingleQuote(remoteTar);
    final extract =
        'mkdir -p $qRemote && tar -xf $qRemoteTar -C "\$(dirname $qRemote)" && rm -f -- $qRemoteTar';
    final res = await c._runSsh(extract);
    if (!res.success) {
      throw StepExecutionException('remote extract failed', stderr: res.stderr);
    }
  } finally {
    try {
      await File(tmpTar).delete();
    } catch (_) {}
  }
}

bool _isDangerousPathImpl(String path) {
  final normalized = _normalizeProfileDeletePathImpl(path);
  if (normalized == null) return true;
  const dangerous = {
    '/',
    '/bin',
    '/boot',
    '/etc',
    '/home',
    '/lib',
    '/lib64',
    '/opt',
    '/root',
    '/run',
    '/sbin',
    '/srv',
    '/sys',
    '/usr',
    '/var',
  };
  if (dangerous.contains(normalized)) return true;
  const protectedPrefixes = [
    '/bin/',
    '/boot/',
    '/dev/',
    '/etc/',
    '/lib/',
    '/lib64/',
    '/proc/',
    '/root/',
    '/run/',
    '/sbin/',
    '/sys/',
    '/usr/',
    '/var/',
  ];
  return protectedPrefixes.any(normalized.startsWith);
}

String? _normalizeProfileDeletePathImpl(String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty || trimmed.startsWith('-') || !trimmed.startsWith('/')) {
    return null;
  }
  final segments = <String>[];
  for (final segment in trimmed.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') return null;
    segments.add(segment);
  }
  if (segments.isEmpty) return '/';
  return '/${segments.join('/')}';
}

/// Build a `VAR=value VAR2=value2 ` prefix for a script step's
/// `env:` map. Keys MUST match `[A-Za-z_][A-Za-z0-9_]*` (the POSIX
/// shell identifier grammar) so a profile cannot inject shell syntax
/// through a key name; values are single-quoted regardless of
/// content.
String _buildEnvPrefixImpl(Object? rawEnv) {
  if (rawEnv == null) return '';
  if (rawEnv is! Map) {
    throw StepExecutionException(
      'script step `env:` must be a map, got ${rawEnv.runtimeType}',
    );
  }
  final validKey = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
  final buf = StringBuffer();
  rawEnv.forEach((k, v) {
    final key = '$k';
    if (!validKey.hasMatch(key)) {
      throw StepExecutionException(
        'env key "$key" is not a valid shell identifier',
      );
    }
    buf
      ..write(key)
      ..write('=')
      ..write(shellSingleQuote('${v ?? ''}'))
      ..write(' ');
  });
  return buf.toString();
}

String _validatedScriptInterpreterImpl(Object? raw) {
  final interpreter = raw as String? ?? 'bash';
  final commandName = RegExp(r'^[A-Za-z_][A-Za-z0-9._+-]*$');
  final absolutePath = RegExp(r'^/(?:[A-Za-z0-9._+-]+/)*[A-Za-z0-9._+-]+$');
  if (!commandName.hasMatch(interpreter) &&
      !absolutePath.hasMatch(interpreter)) {
    throw StepExecutionException(
      'script interpreter "$interpreter" is not a safe executable name',
    );
  }
  return interpreter;
}

void _validateHttpsGitRepoImpl(String value, String label) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.userInfo.isNotEmpty) {
    throw StepExecutionException(
      '$label must be an https:// URL with no credentials, query, or fragment',
    );
  }
}

void _validateGitRefImpl(String value, String label) {
  if (value.isEmpty ||
      value.startsWith('-') ||
      value.startsWith('/') ||
      value.contains('..') ||
      value.contains('\\') ||
      !RegExp(r'^[A-Za-z0-9._/-]+$').hasMatch(value)) {
    throw StepExecutionException('$label "$value" is not a safe git ref');
  }
}

void _validateRemoteInstallPathImpl(String value, String label) {
  final trimmed = value.trim();
  if (trimmed.isEmpty ||
      trimmed.startsWith('-') ||
      trimmed.contains('\u0000') ||
      trimmed.split('/').contains('..') ||
      (!trimmed.startsWith('/') &&
          trimmed != '~' &&
          !trimmed.startsWith('~/'))) {
    throw StepExecutionException('$label "$value" is not a safe remote path');
  }
}

String _safeRemoteBasenameImpl(String value, String label) {
  final base = p.basename(value);
  final safe = base.replaceAll(RegExp(r'[^A-Za-z0-9._+-]'), '_');
  if (safe.isEmpty || safe == '.' || safe == '..' || safe.startsWith('-')) {
    throw StepExecutionException('$label "$base" is not a safe file name');
  }
  return safe;
}

/// Expand `{{...}}` templates in [template].
///
/// When [shellSafe] is true every substituted value is wrapped with
/// [shellSingleQuote] (or [shellPathEscape] for known-path keys) so
/// the result can be safely passed to a shell. The `{{timestamp}}`
/// value is always safe and needs no quoting.
String _renderImpl(
  WizardController c,
  String template, {
  bool shellSafe = false,
}) {
  String q(String v, {bool isPath = false}) {
    if (!shellSafe) return v;
    return isPath ? shellPathEscape(v) : shellSingleQuote(v);
  }

  return template.replaceAllMapped(RegExp(r'\{\{([^}]+)\}\}'), (m) {
    final key = m.group(1)!.trim();
    if (key == 'timestamp') {
      // Deterministic and safe - no shell metacharacters possible.
      return DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    }
    if (key.startsWith('decisions.')) {
      final v =
          '${c._state.decisions[key.substring('decisions.'.length)] ?? ''}';
      return q(v);
    }
    if (key.startsWith('profile.')) {
      final v = '${c._profile?.raw[key.substring('profile.'.length)] ?? ''}';
      return q(v);
    }
    if (key.startsWith('firmware.')) {
      final fw = c._selectedFirmware();
      if (fw == null) return q('');
      switch (key) {
        case 'firmware.install_path':
          return q(fw.installPath ?? '', isPath: true);
        case 'firmware.venv_path':
          return q(fw.venvPath ?? '', isPath: true);
        case 'firmware.id':
          return q(fw.id);
        case 'firmware.ref':
          return q(fw.ref);
        case 'firmware.repo':
          return q(fw.repo);
      }
    }
    return m.group(0)!;
  });
}

/// 16 hex chars from Random.secure(). Good enough to make a `/tmp`
/// path unguessable for the duration of a session; cheaper than
/// pulling a uuid package for a single call site.
String _randomSuffixImpl() {
  final rng = Random.secure();
  final bytes = List<int>.generate(8, (_) => rng.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
