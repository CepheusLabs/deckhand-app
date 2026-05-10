import 'dart:convert';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_test/flutter_test.dart';

const _testSession = SshSession(id: 's1', host: 'h', port: 22, user: 'u');

void main() {
  group('RunState', () {
    test('round-trips an empty state to JSON', () {
      final s = RunState.empty(
        deckhandVersion: '26.4.25-1731',
        profileId: 'sovol_zero',
        profileCommit: 'abc123',
      );
      final j = s.toJson();
      expect(j['schema'], 'deckhand.run_state/1');
      expect(j['profile_id'], 'sovol_zero');
      expect(j['steps'], isEmpty);

      final round = RunState.fromJson(j);
      expect(round.profileId, s.profileId);
      expect(round.profileCommit, s.profileCommit);
      expect(round.startedAt, s.startedAt);
    });

    test('appending preserves history of repeated step ids', () {
      final s0 = RunState.empty(
        deckhandVersion: '1',
        profileId: 'p',
        profileCommit: 'c',
      );
      final firstAttempt = RunStateStep(
        id: 'firmware_clone',
        status: RunStateStatus.failed,
        startedAt: DateTime.utc(2026, 4, 25),
        finishedAt: DateTime.utc(2026, 4, 25, 0, 1),
        inputHash: 'sha256:111',
        error: 'boom',
        exitCode: 1,
      );
      final secondAttempt = RunStateStep(
        id: 'firmware_clone',
        status: RunStateStatus.completed,
        startedAt: DateTime.utc(2026, 4, 25, 0, 5),
        finishedAt: DateTime.utc(2026, 4, 25, 0, 6),
        inputHash: 'sha256:111',
      );
      final s1 = s0.appending(firstAttempt).appending(secondAttempt);
      expect(s1.steps, hasLength(2));
      expect(s1.lastFor('firmware_clone')?.status, RunStateStatus.completed);
    });

    test('upsertingLast replaces in-progress with terminal state', () {
      final s0 = RunState.empty(
        deckhandVersion: '1',
        profileId: 'p',
        profileCommit: 'c',
      );
      final pending = RunStateStep(
        id: 'apt_install',
        status: RunStateStatus.inProgress,
        startedAt: DateTime.utc(2026, 4, 25),
        inputHash: 'sha256:abc',
      );
      final completed = RunStateStep(
        id: 'apt_install',
        status: RunStateStatus.completed,
        startedAt: DateTime.utc(2026, 4, 25),
        finishedAt: DateTime.utc(2026, 4, 25, 0, 0, 30),
        inputHash: 'sha256:abc',
      );
      final s1 = s0.appending(pending).upsertingLast(completed);
      expect(s1.steps, hasLength(1));
      expect(s1.steps.single.status, RunStateStatus.completed);
    });

    test('rejects a payload that is not a deckhand run state', () {
      expect(
        () => RunState.fromJson(const {'schema': 'something-else'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('drops malformed step fields instead of crashing', () {
      final state = RunState.fromJson(const {
        'schema': 'deckhand.run_state/1',
        'deckhand_version': 42,
        'profile_id': false,
        'profile_commit': ['bad'],
        'started_at': 7,
        'steps': [
          {
            'id': 'install_stack',
            'status': 99,
            'started_at': false,
            'finished_at': 13,
            'input_hash': null,
            'output': {'ok': true, 1: 'bad key'},
            'error': ['not', 'a', 'string'],
            'exit_code': 'bad',
            'skip_reason': {'not': 'a string'},
          },
          'not a map',
        ],
      });

      expect(state.deckhandVersion, '');
      expect(state.profileId, '');
      expect(state.profileCommit, '');
      expect(state.steps, hasLength(1));
      expect(state.steps.single.id, 'install_stack');
      expect(state.steps.single.status, RunStateStatus.unknown);
      expect(state.steps.single.inputHash, '');
      expect(state.steps.single.output, {'ok': true});
      expect(state.steps.single.error, isNull);
      expect(state.steps.single.exitCode, isNull);
      expect(state.steps.single.skipReason, isNull);
    });
  });

  group('canonicalInputBytes', () {
    test('produces the same bytes regardless of map order', () {
      final a = canonicalInputBytes({'b': 2, 'a': 1});
      final b = canonicalInputBytes({'a': 1, 'b': 2});
      expect(a, equals(b));
    });

    test('list order is significant', () {
      final a = canonicalInputBytes({
        'paths': const ['x', 'y'],
      });
      final b = canonicalInputBytes({
        'paths': const ['y', 'x'],
      });
      expect(a, isNot(equals(b)));
    });

    test('nested maps are normalized recursively', () {
      final a = canonicalInputBytes({
        'profile': {'ref': 'main', 'repo': 'https://x/y'},
      });
      final b = canonicalInputBytes({
        'profile': {'repo': 'https://x/y', 'ref': 'main'},
      });
      expect(utf8.decode(a), equals(utf8.decode(b)));
    });
  });

  group('RunStateStore', () {
    test('load returns null when the remote file is empty', () async {
      final ssh = _CapturingSsh(
        stdoutReplies: [
          // `cat ... 2>/dev/null || true` → empty stdout when missing.
          const SshCommandResult(stdout: '', stderr: '', exitCode: 0),
        ],
      );
      final store = RunStateStore(ssh: ssh);
      final got = await store.load(_testSession);
      expect(got, isNull);
      // The command was issued.
      expect(ssh.commands, hasLength(1));
      expect(ssh.commands.single, contains('cat'));
      expect(ssh.commands.single, contains('run-state.json'));
    });

    test('load tolerates malformed JSON by returning null', () async {
      final ssh = _CapturingSsh(
        stdoutReplies: [
          const SshCommandResult(
            stdout: 'not valid json',
            stderr: '',
            exitCode: 0,
          ),
        ],
      );
      final store = RunStateStore(ssh: ssh);
      expect(await store.load(_testSession), isNull);
    });

    test('load recovers schema-valid JSON with bad optional scalars', () async {
      final ssh = _CapturingSsh(
        stdoutReplies: [
          const SshCommandResult(
            stdout:
                '{"schema":"deckhand.run_state/1","started_at":false,"steps":[]}',
            stderr: '',
            exitCode: 0,
          ),
        ],
      );
      final store = RunStateStore(ssh: ssh);
      final state = await store.load(_testSession);
      expect(state, isNotNull);
      expect(state!.steps, isEmpty);
    });

    test('load round-trips a real RunState', () async {
      final original =
          RunState.empty(
            deckhandVersion: '26.4.25-1731',
            profileId: 'sovol_zero',
            profileCommit: 'abc',
          ).appending(
            RunStateStep(
              id: 'firmware_clone',
              status: RunStateStatus.completed,
              startedAt: DateTime.utc(2026, 4, 25),
              finishedAt: DateTime.utc(2026, 4, 25, 0, 5),
              inputHash: 'sha256:1',
            ),
          );
      final ssh = _CapturingSsh(
        stdoutReplies: [
          SshCommandResult(
            stdout: const JsonEncoder().convert(original.toJson()),
            stderr: '',
            exitCode: 0,
          ),
        ],
      );
      final store = RunStateStore(ssh: ssh);
      final got = await store.load(_testSession);
      expect(got, isNotNull);
      expect(got!.profileId, 'sovol_zero');
      expect(got.steps, hasLength(1));
      expect(got.steps.single.status, RunStateStatus.completed);
    });

    test('save issues mkdir + base64-decode + atomic mv', () async {
      final ssh = _CapturingSsh(
        stdoutReplies: [
          const SshCommandResult(stdout: '', stderr: '', exitCode: 0),
        ],
      );
      final store = RunStateStore(ssh: ssh);
      final state = RunState.empty(
        deckhandVersion: 'v',
        profileId: 'p',
        profileCommit: 'c',
      );
      await store.save(_testSession, state);
      expect(ssh.commands, hasLength(1));
      final cmd = ssh.commands.single;
      // Atomic-write idiom: mkdir + decode-into-tmp + mv.
      expect(cmd, contains('mkdir -p'));
      expect(cmd, contains('base64 -d'));
      expect(cmd, contains('.tmp'));
      expect(cmd, contains('mv'));
      expect(cmd, contains('rm -f'));
      expect(cmd, contains('run-state.json'));
    });

    test('save throws RunStateWriteException on non-zero exit', () async {
      final ssh = _CapturingSsh(
        stdoutReplies: [
          const SshCommandResult(
            stdout: '',
            stderr: 'mv: permission denied',
            exitCode: 1,
          ),
        ],
      );
      final store = RunStateStore(ssh: ssh);
      final state = RunState.empty(
        deckhandVersion: 'v',
        profileId: 'p',
        profileCommit: 'c',
      );
      await expectLater(
        store.save(_testSession, state),
        throwsA(
          isA<RunStateWriteException>()
              .having((e) => e.exitCode, 'exitCode', 1)
              .having((e) => e.stderr, 'stderr', contains('permission denied')),
        ),
      );
    });

    test('save embeds the JSON via base64 (no shell-quoting bugs)', () async {
      // The JSON includes characters that would break naive shell
      // single-quoting if the encoder didn't go through base64.
      final ssh = _CapturingSsh(
        stdoutReplies: [
          const SshCommandResult(stdout: '', stderr: '', exitCode: 0),
        ],
      );
      final store = RunStateStore(ssh: ssh);
      final state =
          RunState.empty(
            deckhandVersion: '1',
            profileId: 'p',
            profileCommit: 'c',
          ).appending(
            RunStateStep(
              id: 'tricky',
              status: RunStateStatus.completed,
              startedAt: DateTime.utc(2026, 4, 25),
              inputHash: 'sha256:1',
              // Embed a single quote and a newline.
              error: "got 'undefined' on\nthe second line",
            ),
          );
      await store.save(_testSession, state);
      final cmd = ssh.commands.single;
      // The command embeds an `printf %s 'BASE64...' | base64 -d` —
      // never the raw JSON. Verify the raw payload is NOT in the
      // command (which would mean shell-quoting was needed but
      // omitted).
      expect(cmd, isNot(contains("got 'undefined'")));
      expect(cmd, contains('base64 -d'));
    });

    test(
      'tilde remote paths expand through HOME instead of single quotes',
      () async {
        final ssh = _CapturingSsh(
          stdoutReplies: [
            const SshCommandResult(stdout: '', stderr: '', exitCode: 0),
          ],
        );
        final store = RunStateStore(ssh: ssh);
        final state = RunState.empty(
          deckhandVersion: 'v',
          profileId: 'p',
          profileCommit: 'c',
        );
        await store.save(_testSession, state);
        final cmd = ssh.commands.single;
        expect(cmd, contains(r'"$HOME"/'));
        expect(cmd, isNot(contains("'~/.deckhand")));
      },
    );
  });
}

/// Single-purpose SshService fake: returns canned [SshCommandResult]s
/// for [run] calls in order, captures every command for assertions.
class _CapturingSsh implements SshService {
  _CapturingSsh({required this.stdoutReplies});

  final List<SshCommandResult> stdoutReplies;
  final commands = <String>[];

  @override
  Future<SshSession> connect({
    required String host,
    int port = 22,
    required SshCredential credential,
    bool acceptHostKey = false,
    String? acceptedHostFingerprint,
  }) async => SshSession(id: 's', host: host, port: port, user: 'x');

  @override
  Future<SshSession> tryDefaults({
    required String host,
    int port = 22,
    required List<SshCredential> credentials,
    bool acceptHostKey = false,
    String? acceptedHostFingerprint,
  }) async => SshSession(id: 's', host: host, port: port, user: 'x');

  @override
  Future<SshCommandResult> run(
    SshSession session,
    String command, {
    Duration timeout = const Duration(seconds: 30),
    String? sudoPassword,
  }) async {
    commands.add(command);
    if (commands.length > stdoutReplies.length) {
      throw StateError('unexpected command #${commands.length}: $command');
    }
    return stdoutReplies[commands.length - 1];
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
