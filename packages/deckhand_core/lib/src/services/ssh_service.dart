/// SSH sessions + command execution against a printer.
///
/// Implementation in `deckhand_ssh` wraps dartssh2. Tests wire fakes.
abstract class SshService {
  Future<SshSession> connect({
    required String host,
    int port = 22,
    required SshCredential credential,
    bool acceptHostKey = false,
    String? acceptedHostFingerprint,
  });

  /// Try [credentials] in order; return the session from the first that
  /// authenticates successfully.
  ///
  /// If the printer's SSH host key is unpinned or mismatched the
  /// implementation MUST propagate the typed exception
  /// ([HostKeyUnpinnedException] / [HostKeyMismatchException]) rather
  /// than treating it as a generic auth failure - the UI distinguishes
  /// these cases.
  Future<SshSession> tryDefaults({
    required String host,
    int port = 22,
    required List<SshCredential> credentials,
    bool acceptHostKey = false,
    String? acceptedHostFingerprint,
  });

  Future<SshCommandResult> run(
    SshSession session,
    String command, {
    Duration timeout = const Duration(seconds: 30),
    String? sudoPassword,
  });

  Stream<String> runStream(SshSession session, String command);

  /// Like [runStream] but yields lines from BOTH stdout and stderr,
  /// and splits on either `\r` or `\n` so progress-style output (git
  /// clone, dd's status=progress, etc.) shows updates live instead of
  /// only when a final newline arrives. Use this for any command
  /// whose progress matters mid-run; ordinary commands should keep
  /// using [runStream] or [run] for their cleaner contracts.
  Stream<String> runStreamMerged(SshSession session, String command);

  Future<int> upload(
    SshSession session,
    String localPath,
    String remotePath, {
    int? mode,
  });

  Future<int> download(SshSession session, String remotePath, String localPath);

  /// Run `du -sk` against each path and return its size in bytes.
  /// Missing paths return 0 rather than erroring — the snapshot
  /// screen shows a list of probable directories and lets the user
  /// pick which exist; "doesn't exist" is just "0 bytes."
  ///
  /// Single round-trip: paths are joined into one shell invocation
  /// guarded by `&&` so an SSH timeout reflects total wall time, not
  /// N-times-per-path.
  Future<Map<String, int>> duPaths(SshSession session, List<String> paths);

  Future<void> disconnect(SshSession session);
}

class SshSession {
  const SshSession({
    required this.id,
    required this.host,
    required this.port,
    required this.user,
  });
  final String id;
  final String host;
  final int port;
  final String user;
}

sealed class SshCredential {
  const SshCredential();
}

class PasswordCredential extends SshCredential {
  const PasswordCredential({required this.user, required this.password});
  final String user;
  final String password;
}

class KeyCredential extends SshCredential {
  const KeyCredential({
    required this.user,
    required this.privateKeyPath,
    this.passphrase,
  });
  final String user;
  final String privateKeyPath;
  final String? passphrase;
}

class SshCommandResult {
  const SshCommandResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
  });
  final String stdout;
  final String stderr;
  final int exitCode;
  bool get success => exitCode == 0;
}
