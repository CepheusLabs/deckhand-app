import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:deckhand_core/deckhand_core.dart';

/// [ArchiveService] backed by dartssh2 — streams `tar -czf - ...` from
/// the printer over the existing SSH session into a host-local file,
/// and reverses the flow to restore.
///
/// Implemented in `deckhand_ssh` (rather than `deckhand_core`)
/// because it depends on an actual session implementation that
/// supports streaming command output. The `runStream` surface on
/// [SshService] is the seam — every adapter that implements it can
/// satisfy the contract.
///
/// **Wire format.** `runStream` is a *line-oriented* text stream;
/// dartssh2 chunks stdout on `\n` and decodes UTF-8. That means we
/// can't ship raw binary tar bytes through it — they'd contain
/// arbitrary 8-bit values that mangle on UTF-8 decode, and a
/// missing newline would buffer the entire archive in memory until
/// the channel closed. So we wrap the tar in base64 + `fold -w 76`
/// on the printer side. `fold` adds a newline every 76 chars,
/// which produces a steady ~57 binary bytes per yielded line,
/// keeps dartssh2's per-line buffer bounded, and is the same shape
/// MIME and PEM-armoured PGP have used since the 80s. The host
/// decodes each line, accumulates into a write stream, and tracks
/// progress.
class DartsshArchiveService implements ArchiveService {
  DartsshArchiveService({required SshService ssh}) : _ssh = ssh;

  final SshService _ssh;

  @override
  Stream<SnapshotProgress> captureRemote({
    required SshSession session,
    required List<String> paths,
    required String archivePath,
  }) async* {
    if (paths.isEmpty) {
      // No work, but emit one terminal progress so the UI's
      // "fraction == 1" check fires.
      yield const SnapshotProgress(bytesCaptured: 0, bytesEstimated: 0);
      // Still create an empty archive so the file's existence is
      // a stable signal that the snapshot ran.
      await File(archivePath).writeAsBytes(const []);
      return;
    }

    // Quote each path for the shell. The printer-side command is:
    //   tar -czf - --ignore-failed-read -- <paths>
    // which streams a tarball to stdout. --ignore-failed-read makes
    // a missing path a warning rather than a hard error so a
    // user-deselected path that no longer exists doesn't fail the
    // snapshot.
    final quoted = paths
        .map((p) => "'${p.replaceAll("'", r"'\''")}'")
        .join(' ');
    final cmd = 'tar -czf - --ignore-failed-read -- $quoted';

    // Wrap the binary stream in chunked base64. See the class doc
    // comment for the rationale; in short, runStream is line-
    // oriented and we need a length-bounded line shape so dartssh2
    // doesn't buffer a multi-MB archive into one line in memory.
    // `fold -w 76` produces a line every 76 base64 chars (= 57
    // binary bytes) which is the MIME / PEM convention.
    final framed = '$cmd | base64 | fold -w 76';

    // Ensure parent dir exists.
    await Directory(File(archivePath).parent.path).create(recursive: true);
    final out = File(archivePath).openWrite();
    var bytes = 0;
    var done = false;
    try {
      await for (final line in _ssh.runStream(session, framed)) {
        // dartssh2's runStream yields stdout as text lines without
        // the trailing newline; base64 is ascii-clean so utf8.encode
        // is round-trip-safe. Trim defensively to drop any \r or
        // stray whitespace the SSH transport might emit.
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        final List<int> chunk;
        try {
          chunk = base64.decode(trimmed);
        } on FormatException {
          // A malformed line is fatal — the archive's integrity
          // can't be guaranteed past it.
          throw StateError('archive stream produced non-base64 line');
        }
        out.add(chunk);
        bytes += chunk.length;
        yield SnapshotProgress(bytesCaptured: bytes, bytesEstimated: 0);
      }
      await out.flush();
      done = true;
    } finally {
      await out.close();
      if (!done) {
        // On any failure, delete the partial archive. Half-written
        // .tar.gz must never look like a valid snapshot.
        try {
          await File(archivePath).delete();
        } on Object {
          /* best-effort */
        }
      }
    }
    yield SnapshotProgress(bytesCaptured: bytes, bytesEstimated: bytes);
  }

  @override
  Future<RestoreResult> restoreRemote({
    required SshSession session,
    required String archivePath,
    required String destDir,
  }) async {
    final file = File(archivePath);
    if (!await file.exists()) {
      return const RestoreResult(
        restoredFiles: [],
        errors: ['archive missing'],
      );
    }
    final validationErrors = await _validateRestoreArchive(archivePath);
    if (validationErrors.isNotEmpty) {
      return RestoreResult(restoredFiles: const [], errors: validationErrors);
    }
    // The previous implementation embedded the entire base64-
    // encoded archive in a single shell command line. That
    // exceeds POSIX `ARG_MAX` (~128 KB on Linux) for any archive
    // larger than ~96 KiB, which is essentially every real
    // printer-config snapshot. Fix: upload the archive to a tmp
    // path on the printer via SFTP, then run a small fixed-size
    // tar command against the uploaded file.
    final remoteTmp =
        '/tmp/deckhand-restore-'
        '${DateTime.now().toUtc().microsecondsSinceEpoch}.tar.gz';
    final qTmp = _shQuote(remoteTmp);
    final qDest = _shQuote(destDir);
    try {
      await _ssh.upload(session, archivePath, remoteTmp, mode: 0x180); // 0o600

      final res = await _ssh.run(
        session,
        'mkdir -p $qDest && tar -xzf $qTmp -C $qDest '
        '--no-same-owner --delay-directory-restore',
        timeout: const Duration(minutes: 5),
      );
      if (!res.success) {
        return RestoreResult(
          restoredFiles: const [],
          errors: ['tar -xzf failed (exit ${res.exitCode}): ${res.stderr}'],
        );
      }
      // Enumerate what we restored from the same uploaded archive
      // (no host re-stream needed).
      final list = await _ssh.run(
        session,
        'tar -tzf $qTmp',
        timeout: const Duration(seconds: 30),
      );
      final restored = list.success
          ? list.stdout
                .split('\n')
                .map((s) => s.trim())
                .where((s) => s.isNotEmpty)
                .toList()
          : <String>[];
      return RestoreResult(restoredFiles: restored, errors: const []);
    } finally {
      // Best-effort tmp cleanup; a failed cleanup is not worth
      // failing the restore over.
      try {
        await _ssh.run(
          session,
          'rm -f $qTmp',
          timeout: const Duration(seconds: 10),
        );
      } on Object {
        /* swallow */
      }
    }
  }

  static String _shQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

  Future<List<String>> _validateRestoreArchive(String archivePath) async {
    final list = await Process.run('tar', ['-tzf', archivePath]);
    if (list.exitCode != 0) {
      return ['tar -tzf failed (exit ${list.exitCode}): ${list.stderr}'];
    }
    final errors = <String>[];
    final names = list.stdout
        .toString()
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty);
    for (final name in names) {
      if (!_isSafeArchiveMemberPath(name)) {
        errors.add('unsafe archive entry path: $name');
      }
    }

    final verbose = await Process.run('tar', ['-tvzf', archivePath]);
    if (verbose.exitCode != 0) {
      return ['tar -tvzf failed (exit ${verbose.exitCode}): ${verbose.stderr}'];
    }
    for (final line
        in verbose.stdout
            .toString()
            .split('\n')
            .where((s) => s.trim().isNotEmpty)) {
      final type = line[0];
      if (type == 'l' || type == 'h') {
        errors.add('unsafe archive entry link: $line');
      }
    }
    return errors;
  }

  bool _isSafeArchiveMemberPath(String raw) {
    final name = raw.replaceAll('\\', '/').trim();
    if (name.isEmpty || name.startsWith('/')) return false;
    if (RegExp(r'^[A-Za-z]:').hasMatch(name)) return false;
    final parts = name.split('/');
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      final isTrailingDirectoryMarker = i == parts.length - 1 && part.isEmpty;
      if (isTrailingDirectoryMarker) continue;
      if (part.isEmpty || part == '..') return false;
    }
    return true;
  }

  @override
  Future<String> archiveSha256(String archivePath) async {
    final f = File(archivePath);
    if (!await f.exists()) {
      throw StateError('archive not found: $archivePath');
    }
    final digest = await sha256.bind(f.openRead()).first;
    return digest.toString();
  }
}
