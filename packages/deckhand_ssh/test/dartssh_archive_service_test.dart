import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ssh/deckhand_ssh.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('DartsshArchiveService', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('deckhand-archive-');
    });
    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } on Object {
        /* best-effort */
      }
    });

    test('captureRemote with no paths writes an empty archive', () async {
      final svc = DartsshArchiveService(ssh: _FakeSsh());
      final out = p.join(tmp.path, 'empty.tar.gz');
      final progress = await svc
          .captureRemote(session: _session, paths: const [], archivePath: out)
          .toList();
      expect(progress, hasLength(1));
      expect(progress.single.bytesCaptured, 0);
      expect(File(out).existsSync(), isTrue);
      expect(File(out).lengthSync(), 0);
    });

    test(
      'captureRemote streams chunked base64 and reassembles bytes',
      () async {
        // Build a known tar.gz so we can assert byte-exact round-trip.
        final source = _buildTarGz({
          'a.txt': utf8.encode('hello\n'),
          'sub/b.txt': utf8.encode('world\n'),
        });

        // Simulate `tar | base64 | fold -w 76` by chunking the base64
        // encoding into 76-char lines. The fake SSH yields each line
        // separately, exactly like dartssh2's runStream would.
        final encoded = base64.encode(source);
        final lines = <String>[];
        for (var i = 0; i < encoded.length; i += 76) {
          final end = (i + 76 < encoded.length) ? i + 76 : encoded.length;
          lines.add(encoded.substring(i, end));
        }

        final ssh = _FakeSsh(
          streamLines: {
            // The capture command suffix that the impl actually sends.
            'tar -czf -': lines,
          },
        );
        final svc = DartsshArchiveService(ssh: ssh);
        final out = p.join(tmp.path, 'snap.tar.gz');
        final progresses = await svc
            .captureRemote(
              session: _session,
              paths: const ['/printer_data/config'],
              archivePath: out,
            )
            .toList();

        // Final progress reports the full byte count.
        expect(progresses.last.bytesCaptured, source.length);
        // Round-trip equality: the file we wrote matches what the
        // streamed-base64 source was.
        expect(File(out).readAsBytesSync(), source);
      },
    );

    test('captureRemote terminates tar options before profile paths', () async {
      final source = _buildTarGz({'a.txt': utf8.encode('hello')});
      final encoded = base64.encode(source);
      final ssh = _FakeSsh(
        streamLines: {
          'tar -czf -': [encoded],
        },
      );
      final svc = DartsshArchiveService(ssh: ssh);
      await svc
          .captureRemote(
            session: _session,
            paths: const ['--checkpoint-action=exec=touch /tmp/pwned'],
            archivePath: p.join(tmp.path, 'safe.tar.gz'),
          )
          .toList();

      expect(ssh.streamCommands.single, contains(' -- '));
      expect(
        ssh.streamCommands.single,
        isNot(contains('--ignore-failed-read \'--checkpoint-action')),
      );
    });

    test(
      'captureRemote deletes the partial archive on a malformed line',
      () async {
        final ssh = _FakeSsh(
          streamLines: {
            'tar -czf -': ['not-base64-!@#'],
          },
        );
        final svc = DartsshArchiveService(ssh: ssh);
        final out = p.join(tmp.path, 'fail.tar.gz');
        await expectLater(
          svc
              .captureRemote(
                session: _session,
                paths: const ['/x'],
                archivePath: out,
              )
              .toList(),
          throwsA(isA<StateError>()),
        );
        expect(File(out).existsSync(), isFalse);
      },
    );

    test('captureRemote propagates SSH stream errors and cleans up', () async {
      final ssh = _FakeSsh(streamErrors: {'tar -czf -': 'broken pipe'});
      final svc = DartsshArchiveService(ssh: ssh);
      final out = p.join(tmp.path, 'broken.tar.gz');
      await expectLater(
        svc
            .captureRemote(
              session: _session,
              paths: const ['/x'],
              archivePath: out,
            )
            .toList(),
        throwsA(anything),
      );
      expect(
        File(out).existsSync(),
        isFalse,
        reason: 'partial archive must not be left behind',
      );
    });

    test('restoreRemote uploads the archive once and runs tar -xzf '
        'against the uploaded path (no shell-line bloat)', () async {
      final source = _buildTarGz({'hello.txt': utf8.encode('hi')});
      final archivePath = p.join(tmp.path, 'a.tar.gz');
      File(archivePath).writeAsBytesSync(source);

      final ssh = _FakeSsh(
        runReplies: {
          // mkdir + tar -xzf
          RegExp(r'mkdir -p .+ && tar -xzf '): const SshCommandResult(
            stdout: '',
            stderr: '',
            exitCode: 0,
          ),
          // tar -tzf for restored-files enumeration
          RegExp(r'^tar -tzf '): const SshCommandResult(
            stdout: 'hello.txt\n',
            stderr: '',
            exitCode: 0,
          ),
          // rm -f for cleanup
          RegExp(r'^rm -f '): const SshCommandResult(
            stdout: '',
            stderr: '',
            exitCode: 0,
          ),
        },
      );
      final svc = DartsshArchiveService(ssh: ssh);
      final res = await svc.restoreRemote(
        session: _session,
        archivePath: archivePath,
        destDir: '/home/user/restore',
      );

      expect(res.errors, isEmpty);
      expect(res.restoredFiles, ['hello.txt']);
      expect(
        ssh.uploadCalls,
        hasLength(1),
        reason: 'archive uploaded exactly once via SFTP',
      );
      // Critical: no command embeds the entire base64 archive
      // (the previous bug). Every command fits comfortably under
      // POSIX ARG_MAX.
      for (final cmd in ssh.runCommands) {
        expect(
          cmd.length,
          lessThan(2048),
          reason: 'restore command must not embed the archive: $cmd',
        );
      }
    });

    test('restoreRemote reports archive missing without an SSH call', () async {
      final ssh = _FakeSsh();
      final svc = DartsshArchiveService(ssh: ssh);
      final res = await svc.restoreRemote(
        session: _session,
        archivePath: p.join(tmp.path, 'nope.tar.gz'),
        destDir: '/x',
      );
      expect(res.errors.single, contains('archive missing'));
      expect(ssh.runCommands, isEmpty);
      expect(ssh.uploadCalls, isEmpty);
    });

    test('restoreRemote rejects traversal archive before upload', () async {
      final archivePath = p.join(tmp.path, 'evil.tar.gz');
      File(
        archivePath,
      ).writeAsBytesSync(_buildTarGz({'../escape.txt': utf8.encode('owned')}));
      final ssh = _FakeSsh();
      final svc = DartsshArchiveService(ssh: ssh);

      final res = await svc.restoreRemote(
        session: _session,
        archivePath: archivePath,
        destDir: '/home/user/restore',
      );

      expect(res.restoredFiles, isEmpty);
      expect(res.errors.single, contains('unsafe archive entry'));
      expect(ssh.uploadCalls, isEmpty);
      expect(ssh.runCommands, isEmpty);
    });

    test('archiveSha256 hashes the file contents', () async {
      final svc = DartsshArchiveService(ssh: _FakeSsh());
      final path = p.join(tmp.path, 'h.tar.gz');
      File(path).writeAsBytesSync([1, 2, 3, 4]);
      final got = await svc.archiveSha256(path);
      // sha256 of [1,2,3,4]
      expect(
        got,
        '9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a',
      );
    });
  });
}

const _session = SshSession(id: 's', host: 'h', port: 22, user: 'u');

List<int> _buildTarGz(Map<String, List<int>> files) {
  final archive = Archive();
  files.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  final tarBytes = TarEncoder().encode(archive);
  // 4.0.9's GZipEncoder is not a const constructor; tests pin the
  // runtime call to keep the test resilient to future archive-package
  // changes.
  // ignore: prefer_const_constructors
  final gzipped = GZipEncoder().encode(tarBytes);
  return gzipped;
}

/// Configurable [SshService] fake. Each test wires it to specific
/// behaviours via the `streamLines` / `streamErrors` / `runReplies`
/// maps. Keys are matched as substrings (or regexes for runReplies)
/// against the command — keeps the tests resilient to small
/// command-shape changes in the real impl.
class _FakeSsh implements SshService {
  _FakeSsh({
    Map<String, List<String>>? streamLines,
    Map<String, String>? streamErrors,
    Map<RegExp, SshCommandResult>? runReplies,
  }) : _streamLines = streamLines ?? const {},
       _streamErrors = streamErrors ?? const {},
       _runReplies = runReplies ?? const {};

  final Map<String, List<String>> _streamLines;
  final Map<String, String> _streamErrors;
  final Map<RegExp, SshCommandResult> _runReplies;

  final runCommands = <String>[];
  final streamCommands = <String>[];
  final uploadCalls = <String>[];

  @override
  Future<SshSession> connect({
    required String host,
    int port = 22,
    required SshCredential credential,
    bool acceptHostKey = false,
    String? acceptedHostFingerprint,
  }) async => SshSession(id: 's', host: host, port: port, user: 'u');

  @override
  Future<SshSession> tryDefaults({
    required String host,
    int port = 22,
    required List<SshCredential> credentials,
    bool acceptHostKey = false,
    String? acceptedHostFingerprint,
  }) async => SshSession(id: 's', host: host, port: port, user: 'u');

  @override
  Future<SshCommandResult> run(
    SshSession session,
    String command, {
    Duration timeout = const Duration(seconds: 30),
    String? sudoPassword,
  }) async {
    runCommands.add(command);
    for (final entry in _runReplies.entries) {
      if (entry.key.hasMatch(command)) return entry.value;
    }
    throw StateError('no reply registered for command: $command');
  }

  @override
  Stream<String> runStream(SshSession session, String command) async* {
    streamCommands.add(command);
    for (final entry in _streamErrors.entries) {
      if (command.contains(entry.key)) {
        throw StateError(entry.value);
      }
    }
    for (final entry in _streamLines.entries) {
      if (command.contains(entry.key)) {
        for (final line in entry.value) {
          yield line;
        }
        return;
      }
    }
  }

  @override
  Stream<String> runStreamMerged(SshSession session, String command) =>
      runStream(session, command);

  @override
  Future<int> upload(
    SshSession session,
    String localPath,
    String remotePath, {
    int? mode,
  }) async {
    uploadCalls.add(remotePath);
    return File(localPath).lengthSync();
  }

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
