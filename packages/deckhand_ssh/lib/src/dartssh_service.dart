import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:deckhand_core/deckhand_core.dart';
import 'package:uuid/uuid.dart';

/// [SshService] backed by dartssh2.
class DartsshService implements SshService {
  DartsshService({SecurityService? security}) : _security = security;

  /// Optional fingerprint store. When null (test harnesses), host-key
  /// verification is skipped and every connect proceeds - matching the
  /// pre-verification behaviour so existing tests keep passing. In
  /// production the app wires [DefaultSecurityService] here and MITM
  /// attempts hit [HostKeyMismatchException].
  final SecurityService? _security;

  final _uuid = const Uuid();
  final _sessions = <String, SSHClient>{};

  @override
  Future<SshSession> connect({
    required String host,
    int port = 22,
    required SshCredential credential,
    bool acceptHostKey = false,
    String? acceptedHostFingerprint,
  }) async {
    final socket = await SSHSocket.connect(host, port);

    // Host-key verification state captured by the async verifier so the
    // outer connect() can rethrow a typed exception after dartssh2 has
    // torn the socket down.
    String? seenFingerprint;
    String? pinnedFingerprint;
    var mismatch = false;
    var unpinned = false;

    Future<bool> verifier(String type, Uint8List fingerprint) async {
      // The verifier must compare against the key fingerprint from
      // dartssh2's actual SSH connection. A pre-scan from ssh-keyscan
      // would be a separate, unauthenticated network observation and
      // cannot prove the server presented the same key here.
      final fpHex = _formatFingerprint(type, fingerprint);
      seenFingerprint = fpHex;

      // Security-service-less callers (test fakes, etc.) fall back to
      // accept-all - we cannot verify without a store, and forcing a
      // store into tests would ripple through every fake.
      if (_security == null) return true;

      pinnedFingerprint = await _security.pinnedHostFingerprint(host);
      if (pinnedFingerprint == null) {
        if (acceptHostKey) {
          if (acceptedHostFingerprint == null ||
              !_constantTimeEquals(acceptedHostFingerprint, fpHex)) {
            mismatch = true;
            return false;
          }
          await _security.pinHostFingerprint(host: host, fingerprint: fpHex);
          return true;
        }
        unpinned = true;
        return false;
      }
      final ok = _constantTimeEquals(pinnedFingerprint!, fpHex);
      if (!ok) mismatch = true;
      return ok;
    }

    SSHClient client;
    switch (credential) {
      case PasswordCredential(:final user, :final password):
        client = SSHClient(
          socket,
          username: user,
          onPasswordRequest: () => password,
          onVerifyHostKey: verifier,
        );
      case KeyCredential(:final user, :final privateKeyPath, :final passphrase):
        final pem = await File(privateKeyPath).readAsString();
        client = SSHClient(
          socket,
          username: user,
          identities: SSHKeyPair.fromPem(pem, passphrase),
          onVerifyHostKey: verifier,
        );
    }

    try {
      await client.authenticated;
    } catch (e) {
      client.close();
      // Prefer the typed host-key errors over the generic auth/transport
      // failure dartssh2 throws when the verifier rejects.
      if (mismatch) {
        throw HostKeyMismatchException(
          host: host,
          fingerprint: seenFingerprint ?? 'unknown',
        );
      }
      if (unpinned) {
        throw HostKeyUnpinnedException(
          host: host,
          fingerprint: seenFingerprint ?? 'unknown',
        );
      }
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

  /// Format dartssh2's connection fingerprint without pretending every
  /// byte shape is MD5. dartssh2 currently supplies the fingerprint
  /// bytes for the key presented on this SSH connection; the label is
  /// chosen from the byte length so pins stay understandable.
  /// This is the only value used for trust decisions because it is
  /// the fingerprint of the key presented on this SSH connection.
  String _formatFingerprint(String type, Uint8List fingerprint) {
    final label = switch (fingerprint.length) {
      16 => 'MD5',
      32 => 'SHA256',
      _ => 'HEX',
    };
    if (label == 'SHA256') {
      return '$type SHA256:${base64.encode(fingerprint).replaceAll('=', '')}';
    }
    final buf = StringBuffer(type)..write(' $label:');
    for (var i = 0; i < fingerprint.length; i++) {
      if (i > 0) buf.write(':');
      buf.write(fingerprint[i].toRadixString(16).padLeft(2, '0'));
    }
    return buf.toString();
  }

  /// Constant-time string compare to avoid leaking fingerprint
  /// characters via early-exit timing. Overkill for local-network MITM
  /// but cheap.
  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  @override
  Future<SshSession> tryDefaults({
    required String host,
    int port = 22,
    required List<SshCredential> credentials,
    bool acceptHostKey = false,
    String? acceptedHostFingerprint,
  }) async {
    Object? lastError;
    for (final cred in credentials) {
      try {
        return await connect(
          host: host,
          port: port,
          credential: cred,
          acceptHostKey: acceptHostKey,
          acceptedHostFingerprint: acceptedHostFingerprint,
        );
      } on HostKeyMismatchException {
        // Host-key errors are not credential-failure - don't silently
        // try more passwords or the user gets a misleading "none of
        // them worked" when the real problem is MITM.
        rethrow;
      } on HostKeyUnpinnedException {
        rethrow;
      } catch (e) {
        lastError = e;
      }
    }
    throw SshAuthException(host: host, cause: lastError);
  }

  @override
  Future<SshCommandResult> run(
    SshSession session,
    String command, {
    Duration timeout = const Duration(seconds: 30),
    String? sudoPassword,
  }) async {
    final client = _requireClient(session);

    // Previous implementation built a single shell string of the form
    //   echo '<password>' | sudo -S <cmd>
    // and handed it to client.execute. That meant the cleartext
    // password lived inside the command line of the remote process
    // for the duration of the exec AND inside any library-level
    // logging dartssh2 might add later. New approach: use sudo -S
    // but write the password to stdin directly instead of piping it
    // from an echo that lives in the command string.
    final String effectiveCmd;
    if (sudoPassword != null) {
      // `cat | sudo -S` reads the password from our session stdin.
      // `exec` swaps the process image so the original cat is gone
      // by the time the caller's command runs.
      effectiveCmd = 'sudo -S -p "" $command';
    } else {
      effectiveCmd = command;
    }

    final ssh = await client.execute(effectiveCmd);
    if (sudoPassword != null) {
      // Feed the password + newline as the first thing sudo reads.
      // Then close stdin so the remote `sudo` stops waiting.
      ssh.stdin.add(utf8.encode('$sudoPassword\n'));
      await ssh.stdin.close();
    }
    // Drain stdout/stderr to completion BEFORE returning. The previous
    // implementation `await`ed `ssh.done` and then immediately
    // cancelled the listeners — which dropped any bytes buffered
    // between `done` firing and the next event-loop turn that would
    // have pumped them through. For payloads small enough to fit in a
    // single SSH packet (a 23-byte file via `cat`, a `pwd` result),
    // this manifested as silently empty `stdout` even though `cat`
    // exited 0 and the underlying file was perfectly fine.
    //
    // `fold` over each stream returns a future that only completes
    // when the stream is closed (which happens when the channel
    // closes). Wrapping the wait in `Future.wait` with `ssh.done`
    // means we wait for ALL THREE: command exit, stdout drain, and
    // stderr drain. The timeout still fires if anything hangs.
    final stdoutFuture = ssh.stdout.fold<List<int>>(
      <int>[],
      (acc, chunk) => acc..addAll(chunk),
    );
    final stderrFuture = ssh.stderr.fold<List<int>>(
      <int>[],
      (acc, chunk) => acc..addAll(chunk),
    );
    try {
      await Future.wait([
        ssh.done,
        stdoutFuture,
        stderrFuture,
      ]).timeout(timeout);
    } on TimeoutException {
      ssh.close();
      throw TimeoutException('ssh.run timed out after $timeout');
    }
    final stdoutBytes = await stdoutFuture;
    final stderrBytes = await stderrFuture;

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
  Stream<String> runStreamMerged(SshSession session, String command) {
    final client = _requireClient(session);
    final controller = StreamController<String>();
    () async {
      final ssh = await client.execute(command);
      // Carriage-return-aware splitter: git clone (and many other
      // progress-aware tools) overwrites a single line via \r without
      // terminating it with \n. LineSplitter would buffer those
      // updates indefinitely. Yield on either \r or \n instead so the
      // UI sees progress as it lands.
      final pending = StringBuffer();
      void emit(List<int> chunk) {
        if (chunk.isEmpty) return;
        final s = utf8.decode(chunk, allowMalformed: true);
        for (var i = 0; i < s.length; i++) {
          final ch = s[i];
          if (ch == '\n' || ch == '\r') {
            if (pending.isNotEmpty) {
              controller.add(pending.toString());
              pending.clear();
            }
          } else {
            pending.write(ch);
          }
        }
      }

      final out = ssh.stdout.listen(emit);
      final err = ssh.stderr.listen(emit);
      await ssh.done;
      await out.cancel();
      await err.cancel();
      if (pending.isNotEmpty) {
        controller.add(pending.toString());
      }
      await controller.close();
    }();
    return controller.stream;
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
      // Apply mode via SFTP fsetstat the instant the data lands so
      // there is no TOCTOU window between the write and a separate
      // `chmod` command. The previous implementation skipped this
      // entirely, meaning the askpass helper (which contains the SSH
      // password in cleartext) was world-readable from write-time
      // until a follow-up chmod ran.
      if (mode != null) {
        await handle.setStat(SftpFileAttrs(mode: SftpFileMode.value(mode)));
      }
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
  Future<Map<String, int>> duPaths(
    SshSession session,
    List<String> paths,
  ) async {
    if (paths.isEmpty) return const {};
    // One round-trip: emit `<size>\t<path>` per path. Missing paths
    // collapse to size 0 via `du -s 2>/dev/null || echo 0\t<path>`
    // so the output shape is uniform regardless of whether each
    // path exists. The shell quote pattern matches every other
    // SSH command in the codebase (shellSingleQuote in deckhand_core).
    final lines = paths
        .map(
          (p) =>
              "du -sb ${shellSingleQuote(p)} 2>/dev/null || "
              "printf '0\\t%s\\n' ${shellSingleQuote(p)}",
        )
        .join(' ; ');
    final result = await run(
      session,
      lines,
      timeout: const Duration(seconds: 30),
    );
    final sizes = <String, int>{};
    for (final line in result.stdout.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final tabIdx = trimmed.indexOf('\t');
      if (tabIdx < 0) continue;
      final sizeStr = trimmed.substring(0, tabIdx);
      final path = trimmed.substring(tabIdx + 1);
      sizes[path] = int.tryParse(sizeStr) ?? 0;
    }
    // Backfill zeros for any path that didn't appear in output.
    for (final p in paths) {
      sizes.putIfAbsent(p, () => 0);
    }
    return sizes;
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
}

// SshAuthException was duplicated here and in deckhand_core/errors.dart.
// The core version is the one plumbed through the rest of the app
// (UI catches DeckhandException at screen boundaries), so this
// duplicate has been removed. Callers should import it from
// package:deckhand_core/deckhand_core.dart.
