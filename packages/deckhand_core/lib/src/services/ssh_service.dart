/// SSH sessions + command execution against a printer.
///
/// Implementation in `deckhand_ssh` wraps dartssh2. Tests wire fakes.
abstract class SshService {
  Future<SshSession> connect({
    required String host,
    int port = 22,
    required SshCredential credential,
    bool acceptHostKey = false,
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
  });

  Future<SshCommandResult> run(
    SshSession session,
    String command, {
    Duration timeout = const Duration(seconds: 30),
    String? sudoPassword,
  });

  Stream<String> runStream(SshSession session, String command);

  Future<int> upload(
    SshSession session,
    String localPath,
    String remotePath, {
    int? mode,
  });

  Future<int> download(SshSession session, String remotePath, String localPath);

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
