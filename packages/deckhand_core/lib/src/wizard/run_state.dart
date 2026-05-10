import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

import '../services/ssh_service.dart';
import '../shell/shell_quoting.dart';

/// On-printer record of which install steps have actually run.
///
/// Pairs with [WizardState] (host-side decisions) — see
/// [docs/STEP-IDEMPOTENCY.md] for the full model:
///   - host wizard state file = "what the user chose"
///   - printer run state file = "what got done"
///
/// The UI reads this on entering S900 to decide which steps to skip,
/// resume, or re-run, and writes it after every transition so a crash,
/// dropped SSH session, or power blip is recoverable without
/// re-executing already-completed steps.
@immutable
class RunState {
  const RunState({
    required this.deckhandVersion,
    required this.profileId,
    required this.profileCommit,
    required this.startedAt,
    required this.steps,
  });

  factory RunState.empty({
    required String deckhandVersion,
    required String profileId,
    required String profileCommit,
  }) => RunState(
    deckhandVersion: deckhandVersion,
    profileId: profileId,
    profileCommit: profileCommit,
    startedAt: DateTime.now().toUtc(),
    steps: const [],
  );

  factory RunState.fromJson(Map<String, dynamic> json) {
    if (json['schema'] != _schema) {
      throw const FormatException('not a deckhand run-state document');
    }
    final stepsRaw = json['steps'];
    final steps = <RunStateStep>[];
    if (stepsRaw is List) {
      for (final entry in stepsRaw) {
        final step = _stringKeyMap(entry);
        if (step != null) steps.add(RunStateStep.fromJson(step));
      }
    }
    return RunState(
      deckhandVersion: _jsonString(json['deckhand_version']) ?? '',
      profileId: _jsonString(json['profile_id']) ?? '',
      profileCommit: _jsonString(json['profile_commit']) ?? '',
      startedAt: _jsonDate(json['started_at']) ?? DateTime.now().toUtc(),
      steps: List.unmodifiable(steps),
    );
  }

  static const _schema = 'deckhand.run_state/1';

  final String deckhandVersion;
  final String profileId;
  final String profileCommit;
  final DateTime startedAt;
  final List<RunStateStep> steps;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'schema': _schema,
    'deckhand_version': deckhandVersion,
    'profile_id': profileId,
    'profile_commit': profileCommit,
    'started_at': startedAt.toIso8601String(),
    'steps': [for (final s in steps) s.toJson()],
  };

  /// Returns the last recorded entry for [stepId], or null if absent.
  /// Multiple entries with the same id can exist when the user jumped
  /// back and changed inputs between attempts; the last entry is the
  /// one that reflects the current decision graph.
  RunStateStep? lastFor(String stepId) {
    for (var i = steps.length - 1; i >= 0; i--) {
      if (steps[i].id == stepId) return steps[i];
    }
    return null;
  }

  /// Append [step], returning a new RunState. Existing entries with
  /// the same id are preserved so the audit trail of attempts is
  /// intact; [lastFor] reflects the appended record.
  RunState appending(RunStateStep step) => RunState(
    deckhandVersion: deckhandVersion,
    profileId: profileId,
    profileCommit: profileCommit,
    startedAt: startedAt,
    steps: List.unmodifiable([...steps, step]),
  );

  /// Replace the most recent entry for [step.id] in place. Useful for
  /// updating an `in_progress` record to `completed` / `failed`
  /// without leaving the in-progress entry behind. If no entry for
  /// the id exists, this behaves like [appending].
  RunState upsertingLast(RunStateStep step) {
    for (var i = steps.length - 1; i >= 0; i--) {
      if (steps[i].id == step.id) {
        final next = [...steps];
        next[i] = step;
        return RunState(
          deckhandVersion: deckhandVersion,
          profileId: profileId,
          profileCommit: profileCommit,
          startedAt: startedAt,
          steps: List.unmodifiable(next),
        );
      }
    }
    return appending(step);
  }

  RunState merging(RunState other) {
    if (other.steps.isEmpty) return this;
    if (steps.isEmpty) {
      return RunState(
        deckhandVersion: deckhandVersion,
        profileId: profileId,
        profileCommit: profileCommit,
        startedAt: other.startedAt.isBefore(startedAt)
            ? other.startedAt
            : startedAt,
        steps: List.unmodifiable(other.steps),
      );
    }
    return RunState(
      deckhandVersion: deckhandVersion,
      profileId: profileId,
      profileCommit: profileCommit,
      startedAt: other.startedAt.isBefore(startedAt)
          ? other.startedAt
          : startedAt,
      steps: List.unmodifiable([...other.steps, ...steps]),
    );
  }
}

/// One executed step. The fields mirror the on-disk JSON in
/// [docs/STEP-IDEMPOTENCY.md].
@immutable
class RunStateStep {
  const RunStateStep({
    required this.id,
    required this.status,
    required this.startedAt,
    required this.inputHash,
    this.finishedAt,
    this.output = const {},
    this.error,
    this.exitCode,
    this.skipReason,
  });

  factory RunStateStep.fromJson(Map<String, dynamic> json) {
    final outputRaw = json['output'];
    final output = <String, Object>{};
    if (outputRaw is Map) {
      outputRaw.forEach((k, v) {
        if (k is String && v != null) output[k] = v as Object;
      });
    }
    return RunStateStep(
      id: _jsonString(json['id']) ?? '',
      status: runStateStatusFromString(_jsonString(json['status'])),
      startedAt: _jsonDate(json['started_at']) ?? DateTime.now().toUtc(),
      finishedAt: _jsonDate(json['finished_at']),
      inputHash: _jsonString(json['input_hash']) ?? '',
      output: Map.unmodifiable(output),
      error: _jsonString(json['error']),
      exitCode: _jsonInt(json['exit_code']),
      skipReason: _jsonString(json['skip_reason']),
    );
  }

  final String id;
  final RunStateStatus status;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final String inputHash;
  final Map<String, Object> output;
  final String? error;
  final int? exitCode;
  final String? skipReason;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'status': status.wireName,
    'started_at': startedAt.toIso8601String(),
    if (finishedAt != null) 'finished_at': finishedAt!.toIso8601String(),
    'input_hash': inputHash,
    if (output.isNotEmpty) 'output': output,
    if (error != null) 'error': error,
    if (exitCode != null) 'exit_code': exitCode,
    if (skipReason != null) 'skip_reason': skipReason,
  };
}

enum RunStateStatus {
  inProgress('in_progress'),
  completed('completed'),
  failed('failed'),
  skipped('skipped'),
  unknown('unknown');

  const RunStateStatus(this.wireName);
  final String wireName;
}

RunStateStatus runStateStatusFromString(String? s) {
  switch (s) {
    case 'in_progress':
      return RunStateStatus.inProgress;
    case 'completed':
      return RunStateStatus.completed;
    case 'failed':
      return RunStateStatus.failed;
    case 'skipped':
      return RunStateStatus.skipped;
    default:
      return RunStateStatus.unknown;
  }
}

/// Reads / writes the run-state file on the printer over an SSH
/// session. The file lives at `~/.deckhand/run-state.json`. Writes
/// are atomic (`tmp → mv`); reads are best-effort (a missing or
/// corrupt file is treated as "no prior run", matching the host-side
/// `WizardStateStore.load` contract).
class RunStateStore {
  const RunStateStore({
    required SshService ssh,
    String remotePath = '~/.deckhand/run-state.json',
  }) : _ssh = ssh,
       _remotePath = remotePath;

  final SshService _ssh;
  final String _remotePath;

  static const _readTimeout = Duration(seconds: 10);
  static const _writeTimeout = Duration(seconds: 15);

  /// Read the run-state from the printer. Returns null when the file
  /// is absent or unparseable.
  Future<RunState?> load(SshSession session) async {
    final result = await _ssh.run(
      session,
      // Quoted for safety even though the path is a constant — the
      // remote path can be overridden by tests, and a future caller
      // shouldn't have to re-derive whether quoting is safe.
      'cat ${shellPathEscape(_remotePath)} 2>/dev/null || true',
      timeout: _readTimeout,
    );
    final body = result.stdout.trim();
    if (body.isEmpty) return null;
    try {
      final json = jsonDecode(body);
      if (json is! Map<String, dynamic>) return null;
      return RunState.fromJson(json);
    } on Object {
      return null;
    }
  }

  /// Persist [state] to the printer. Atomic via tmp + mv; the dest
  /// directory is created if missing.
  Future<void> save(SshSession session, RunState state) async {
    final json = const JsonEncoder.withIndent('  ').convert(state.toJson());
    // base64 round-trip avoids any shell quoting concerns with the
    // JSON payload (newlines, single quotes, dollars). printf %s
    // would also work but base64 is the more honest "binary-safe"
    // choice and matches the pattern used elsewhere in the wizard.
    final encoded = base64.encode(utf8.encode(json));
    final remoteDir = _remotePath.contains('/')
        ? _remotePath.substring(0, _remotePath.lastIndexOf('/'))
        : '.';
    final tmp = '$_remotePath.tmp';
    final qTmp = shellPathEscape(tmp);
    final qRemotePath = shellPathEscape(_remotePath);
    final qRemoteDir = shellPathEscape(remoteDir);
    final cmd =
        'mkdir -p $qRemoteDir && '
        '(printf %s ${shellSingleQuote(encoded)} | base64 -d > '
        '$qTmp && mv $qTmp $qRemotePath || '
        '{ rc=\$?; rm -f $qTmp; exit \$rc; })';
    final result = await _ssh.run(session, cmd, timeout: _writeTimeout);
    if (!result.success) {
      throw RunStateWriteException(
        exitCode: result.exitCode,
        stderr: result.stderr,
      );
    }
  }
}

class RunStateWriteException implements Exception {
  const RunStateWriteException({required this.exitCode, required this.stderr});
  final int exitCode;
  final String stderr;
  @override
  String toString() =>
      'RunStateWriteException(exitCode=$exitCode, stderr=$stderr)';
}

Map<String, dynamic>? _stringKeyMap(Object? value) {
  if (value is! Map) return null;
  final out = <String, dynamic>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is String) out[key] = entry.value;
  }
  return out;
}

String? _jsonString(Object? value) => value is String ? value : null;

int? _jsonInt(Object? value) =>
    value is num && value.isFinite ? value.toInt() : null;

DateTime? _jsonDate(Object? value) {
  final raw = _jsonString(value);
  if (raw == null) return null;
  return DateTime.tryParse(raw)?.toUtc();
}

/// Compute the canonical input hash for a step. Produces a stable
/// `sha256:<hex>` string suitable for storing in
/// [RunStateStep.inputHash] and comparing on resume.
///
/// Implemented as a top-level helper so callers don't have to reach
/// into a service interface for what's really just deterministic
/// JSON-canonicalization plus a SHA-256.
String canonicalInputHash(Map<String, Object?> inputs) {
  final bytes = canonicalInputBytes(inputs);
  return 'sha256:${sha256.convert(bytes)}';
}

/// Canonicalised bytes that [canonicalInputHash] hashes. Exposed
/// separately so tests can pin the byte-level encoding rules
/// independently of the hash function.
List<int> canonicalInputBytes(Map<String, Object?> inputs) {
  final sorted = SplayTreeMapEntries(inputs);
  return utf8.encode(jsonEncode(sorted.encoded));
}

/// Tiny utility class — exposed for tests so they can pin the
/// canonicalization rules without re-inventing them. Sorts keys at
/// every nesting level so the resulting JSON is byte-identical for
/// equivalent inputs regardless of original Map iteration order.
@visibleForTesting
class SplayTreeMapEntries {
  SplayTreeMapEntries(Map<String, Object?> input) : encoded = _normalize(input);

  final Object? encoded;

  static Object? _normalize(Object? v) {
    if (v is Map) {
      final entries = v.entries.toList()
        ..sort((a, b) => a.key.toString().compareTo(b.key.toString()));
      return {for (final e in entries) e.key.toString(): _normalize(e.value)};
    }
    if (v is List) {
      // Lists keep their order — for a `paths: [a, b]` step, [a, b]
      // and [b, a] are different inputs.
      return [for (final item in v) _normalize(item)];
    }
    return v;
  }
}
