import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:deckhand_core/deckhand_core.dart';

import 'shell_quoting.dart';
import 'package:uuid/uuid.dart';

/// [SshService] backed by dartssh2.
class DartsshService implements SshService {
  DartsshService();

  final _uuid = const Uuid();
  final _sessions = <String, SSHClient>{};

  @override
  Future<SshSession> connect({
    required String host,
    int port = 22,
    required SshCredential credential,
    bool acceptHostKey = false,
  }) async {
    final socket = await SSHSocket.connect(host, port);

    SSHClient client;
    switch (credential) {
      case PasswordCredential(:final user, :final password):
        client = SSHClient(
          socket,
          username: user,
          onPasswordRequest: () => password,
        );
      case KeyCredential(:final user, :final privateKeyPath, :final passphrase):
        final pem = await File(privateKeyPath).readAsString();
        client = SSHClient(
          socket,
          username: user,
          identities: SSHKeyPair.fromPem(pem, passphrase),
        );
    }

    try {
      await client.authenticated;
    } catch (e) {
      client.close();
      rethrow;
    }

    final id = _uuid.v4();
    _sessions[id] = client;
    return SshSession(
      id: id,
      host: host,
      port: port,
      user: _userOf(credential),
    );
  }

  @override
  Future<SshSession> tryDefaults({
    required String host,
    int port = 22,
    required List<SshCredential> credentials,
  }) async {
    Object? lastError;
    for (final cred in credentials) {
      try {
        return await connect(host: host, port: port, credential: cred);
      } catch (e) {
        lastError = e;
      }
    }
    throw SshAuthException(
      host: host,
      port: port,
      message: 'None of the default credentials authenticated',
      inner: lastError,
    );
  }

  @override
  Future<SshCommandResult> run(
    SshSession session,
    String command, {
    Duration timeout = const Duration(seconds: 30),
    String? sudoPassword,
  }) async {
    final client = _requireClient(session);
    final effectiveCmd = sudoPassword != null
        ? 'echo ${_shellQuote(sudoPassword)} | sudo -S ${command}'
        : command;

    final ssh = await client.execute(effectiveCmd);
    final stdoutBytes = <int>[];
    final stderrBytes = <int>[];
    final stdoutSub = ssh.stdout.listen(stdoutBytes.addAll);
    final stderrSub = ssh.stderr.listen(stderrBytes.addAll);

    await ssh.done.timeout(
      timeout,
      onTimeout: () {
        ssh.close();
        throw TimeoutException('ssh.run($command) timed out after $timeout');
      },
    );

    await stdoutSub.cancel();
    await stderrSub.cancel();

    return SshCommandResult(
      stdout: utf8.decode(stdoutBytes, allowMalformed: true),
      stderr: utf8.decode(stderrBytes, allowMalformed: true),
      exitCode: ssh.exitCode ?? -1,
    );
  }

  @override
  Stream<String> runStream(SshSession session, String command) async* {
    final client = _requireClient(session);
    final ssh = await client.execute(command);
    await for (final chunk in ssh.stdout) {
      final s = utf8.decode(chunk, allowMalformed: true);
      for (final line in const LineSplitter().convert(s)) {
        yield line;
      }
    }
  }

  @override
  Future<int> upload(
    SshSession session,
    String localPath,
    String remotePath, {
    int? mode,
  }) async {
    final client = _requireClient(session);
    final sftp = await client.sftp();
    final file = File(localPath);
    final bytes = await file.readAsBytes();
    final handle = await sftp.open(
      remotePath,
      mode:
          SftpFileOpenMode.create |
          SftpFileOpenMode.truncate |
          SftpFileOpenMode.write,
    );
    try {
      await handle.writeBytes(bytes);
      // Leaving chmod as a follow-up; dartssh2's SftpFileMode API varies
      // by version and we need a compatibility matrix before wiring it.
      return bytes.length;
    } finally {
      await handle.close();
    }
  }

  @override
  Future<int> download(
    SshSession session,
    String remotePath,
    String localPath,
  ) async {
    final client = _requireClient(session);
    final sftp = await client.sftp();
    final handle = await sftp.open(remotePath, mode: SftpFileOpenMode.read);
    try {
      final bytes = await handle.readBytes();
      await File(localPath).writeAsBytes(bytes);
      return bytes.length;
    } finally {
      await handle.close();
    }
  }

  @override
  Future<void> disconnect(SshSession session) async {
    final client = _sessions.remove(session.id);
    client?.close();
  }

  // --------------------------------------------------------------

  SSHClient _requireClient(SshSession session) {
    final client = _sessions[session.id];
    if (client == null) {
      throw StateError('No SSH client for session ${session.id}');
    }
    return client;
  }

  String _userOf(SshCredential c) => switch (c) {
    PasswordCredential(:final user) => user,
    KeyCredential(:final user) => user,
  };

  // Kept as an instance method for back-compat; delegates to the
  // library-level helper which owns the semantics + tests.
  String _shellQuote(String s) => shellSingleQuote(s);
}

/// Thrown when all credential attempts fail.
class SshAuthException implements Exception {
  SshAuthException({
    required this.host,
    required this.port,
    required this.message,
    this.inner,
  });
  final String host;
  final int port;
  final String message;
  final Object? inner;

  @override
  String toString() => 'SshAuthException($host:$port): $message';
}
