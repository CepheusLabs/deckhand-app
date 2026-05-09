import 'dart:convert';
import 'dart:io';

import 'wizard_flow.dart';

const Object _copyWithUnset = Object();

/// Decision key set once the user has reinstalled the flashed eMMC,
/// powered the printer on, and selected/confirmed the printer that
/// Deckhand should wait for over SSH.
const firstBootReadyForSshWaitDecision = 'first_boot.ready_for_ssh_wait';

/// Immutable snapshot of the wizard at a point in time.
///
/// Only data the wizard owns goes here — no live SSH session, no
/// confirmation tokens, no passwords. The reason: this object is
/// the unit of resume persistence (see [WizardStateStore]), and
/// secrets durably written to disk would let a thief restoring a
/// prior session bypass authentication. The serializer therefore
/// only round-trips the decision graph + nav cursor.
class WizardState {
  const WizardState({
    required this.profileId,
    required this.decisions,
    required this.currentStep,
    required this.flow,
    this.sshHost,
    this.sshPort,
    this.sshUser,
  });

  factory WizardState.initial() => const WizardState(
    profileId: '',
    decisions: {},
    currentStep: 'welcome',
    flow: WizardFlow.none,
  );

  /// Round-trip the wizard state to/from JSON so the app can persist
  /// it between launches and resume after a crash.
  factory WizardState.fromJson(Map<String, dynamic> json) {
    final decisionsRaw = json['decisions'];
    final decisions = <String, Object>{};
    if (decisionsRaw is Map) {
      decisionsRaw.forEach((k, v) {
        if (v != null) decisions[k.toString()] = v as Object;
      });
    }
    final flowRaw = json['flow'] as String? ?? 'none';
    final flow = WizardFlow.values.firstWhere(
      (f) => f.name == flowRaw,
      orElse: () => WizardFlow.none,
    );
    return WizardState(
      profileId: _decodeRequiredString(json['profileId'], ''),
      decisions: decisions,
      currentStep: _decodeRequiredString(json['currentStep'], 'welcome'),
      flow: flow,
      sshHost: _decodeOptionalString(json['sshHost']),
      sshPort: _decodePort(json['sshPort']),
      sshUser: _decodeOptionalString(json['sshUser']),
    );
  }

  final String profileId;
  final Map<String, Object> decisions;
  final String currentStep;
  final WizardFlow flow;
  final String? sshHost;
  final int? sshPort;
  final String? sshUser;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'schema': 'deckhand.wizard_state/1',
    'profileId': profileId,
    'decisions': decisions,
    'currentStep': currentStep,
    'flow': flow.name,
    if (sshHost != null) 'sshHost': sshHost,
    if (sshPort != null) 'sshPort': sshPort,
    if (sshUser != null) 'sshUser': sshUser,
  };

  WizardState copyWith({
    String? profileId,
    Map<String, Object>? decisions,
    String? currentStep,
    WizardFlow? flow,
    Object? sshHost = _copyWithUnset,
    Object? sshPort = _copyWithUnset,
    Object? sshUser = _copyWithUnset,
  }) => WizardState(
    profileId: profileId ?? this.profileId,
    decisions: decisions ?? this.decisions,
    currentStep: currentStep ?? this.currentStep,
    flow: flow ?? this.flow,
    sshHost: identical(sshHost, _copyWithUnset)
        ? this.sshHost
        : sshHost as String?,
    sshPort: identical(sshPort, _copyWithUnset)
        ? this.sshPort
        : sshPort as int?,
    sshUser: identical(sshUser, _copyWithUnset)
        ? this.sshUser
        : sshUser as String?,
  );
}

int? _decodePort(Object? raw) {
  final port = raw is num ? raw.toInt() : null;
  if (port == null || port < 1 || port > 65535) return null;
  return port;
}

String _decodeRequiredString(Object? raw, String fallback) {
  if (raw is! String) return fallback;
  return raw.trim().isEmpty ? fallback : raw;
}

String? _decodeOptionalString(Object? raw) {
  if (raw is! String) return null;
  final value = raw.trim();
  return value.isEmpty ? null : value;
}

/// On-disk persistence layer for [WizardState]. Writes are atomic
/// (`<path>.tmp` → rename) so a crash mid-write leaves the last good
/// snapshot intact. Resume loads are best-effort: corrupt or
/// out-of-schema files are treated as "no resume" rather than hard
/// errors — stale state is never a good reason to block the wizard.
///
/// [errorSink] receives any persistence failure (full disk, locked
/// file, etc.). The wizard does not surface a user-visible error
/// because save failures only matter at the resume boundary, not
/// while the user is making decisions — but the failures need to go
/// somewhere or a corrupted state would be invisible. Wire to a
/// logger; null swallows them (default for tests).
///
/// Tests that need a synchronous, race-free backing store can use
/// [InMemoryWizardStateStore] (see below). Real File I/O against
/// the simulated frame clock makes widget tests flaky.
class WizardStateStore {
  WizardStateStore({required this.path, this.errorSink});

  final String path;
  final void Function(Object error, StackTrace stackTrace)? errorSink;

  // Coalesce-to-latest scheduler. When save() is called repeatedly
  // in quick succession — which the Riverpod provider does, once per
  // controller event — we serialize the actual writes and drop
  // intermediate states on the floor. Without this, two unawaited
  // saves racing to `rename()` could end up with the older state
  // winning, because completion order of unawaited Futures is not
  // well-defined across platforms' FS implementations.
  WizardState? _pending;
  Future<void>? _inFlight;

  Future<WizardState?> load() async {
    final file = File(path);
    if (!await file.exists()) return null;
    try {
      final text = await file.readAsString();
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic>) return null;
      if (json['schema'] != 'deckhand.wizard_state/1') return null;
      return WizardState.fromJson(json);
    } catch (e, st) {
      errorSink?.call(e, st);
      return null;
    }
  }

  /// Schedule a save of [state]. Returns a future that completes when
  /// either this state or a later state that superseded it has been
  /// durably persisted. Safe to call unawaited — write errors are
  /// routed to [errorSink] rather than thrown back at the caller, so
  /// the wizard never blocks on a flaky disk.
  Future<void> save(WizardState state) {
    _pending = state;
    return _inFlight ??= _drain();
  }

  Future<void> _drain() async {
    try {
      while (_pending != null) {
        final snap = _pending!;
        _pending = null;
        try {
          await _writeAtomically(snap);
        } catch (e, st) {
          errorSink?.call(e, st);
        }
      }
    } finally {
      _inFlight = null;
    }
  }

  Future<void> _writeAtomically(WizardState state) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final tmp = File('$path.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(state.toJson()),
    );
    try {
      await tmp.rename(path);
    } on FileSystemException {
      // Some filesystems (e.g. Windows when the target is locked)
      // need an explicit delete before rename. Fall back once.
      if (await file.exists()) await file.delete();
      await tmp.rename(path);
    }
  }

  Future<void> clear() async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }
}

/// Synchronous-resolving WizardStateStore backed by a single
/// in-memory slot. Widget tests use this so the post-frame
/// `_maybeOfferResume` callback never blocks on real `File` I/O —
/// the load/save futures complete on the next microtask, which the
/// test harness's frame pump can drain deterministically.
///
/// Extends [WizardStateStore] (rather than implementing) so it can
/// satisfy the same type while overriding only the three public
/// entry points. The base class's coalesce-scheduler is bypassed
/// because there's nothing to race against in memory.
class InMemoryWizardStateStore extends WizardStateStore {
  InMemoryWizardStateStore({super.errorSink}) : super(path: '<memory>');

  WizardState? _state;

  @override
  Future<WizardState?> load() async => _state;

  @override
  Future<void> save(WizardState state) async {
    _state = state;
  }

  @override
  Future<void> clear() async {
    _state = null;
  }
}
