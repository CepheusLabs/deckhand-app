import 'package:forge_wizard/forge_wizard.dart';

import 'wizard_flow.dart';

export 'package:forge_wizard/forge_wizard.dart' show ForgeWizardConnection;

const Object _copyWithUnset = Object();

/// Decision key set once the user has reinstalled the flashed eMMC,
/// powered the printer on, and selected/confirmed the printer that
/// Deckhand should wait for over SSH.
const firstBootReadyForSshWaitDecision = 'first_boot.ready_for_ssh_wait';

/// Schema marker for the persisted wizard snapshot. Bumping the trailing
/// version invalidates older on-disk files (they load as "no resume").
const _wizardStateSchema = 'deckhand.wizard_state/1';

/// Shared codec that maps the persisted JSON shape onto the
/// app-neutral [ForgeWizardState] fields. Deckhand's `profileId` is the
/// forge `subjectId`; the `flow` enum persists as the forge `flowId`
/// string; the SSH triple is the forge `connection`. Kept module-level
/// so both [WizardState.toJson]/[WizardState.fromJson] and
/// [WizardStateStore] round-trip through exactly one schema definition.
const _wizardStateCodec = ForgeWizardStateCodec(
  schema: _wizardStateSchema,
  subjectIdKey: 'profileId',
  flowIdKey: 'flow',
  connectionHostKey: 'sshHost',
  connectionPortKey: 'sshPort',
  connectionUserKey: 'sshUser',
  defaultFlowId: 'none',
);

/// Lift an app-neutral [ForgeWizardState] (as produced by the forge
/// codec / process) back into the Deckhand [WizardState] subtype. The
/// only Deckhand-specific bit is decoding the `flowId` string into a
/// [WizardFlow]; everything else is carried verbatim. Used as the
/// `convert` callback for [ForgeWizardFlowProcess] / [ForgeWizardStateStore].
WizardState wizardStateFromForge(ForgeWizardState state) {
  if (state is WizardState) return state;
  return WizardState(
    profileId: state.subjectId,
    decisions: state.decisions,
    currentStep: state.currentStepId,
    flow: _flowFromId(state.flowId),
    sshHost: state.connection.host,
    sshPort: state.connection.port,
    sshUser: state.connection.user,
  );
}

WizardFlow _flowFromId(String flowId) => WizardFlow.values.firstWhere(
  (f) => f.name == flowId,
  orElse: () => WizardFlow.none,
);

/// Whether a decision key holds a secret (a user-chosen password or
/// passphrase). Secret decisions are kept in the in-memory decision
/// graph while the wizard runs — the install step still interpolates
/// them via `{{decisions.…}}` — but they MUST NOT be written to disk by
/// [WizardState.toJson] nor leak un-redacted into a debug bundle.
///
/// The rule keys off the final dotted segment so there is no
/// hand-maintained allowlist to drift: `first_boot.password`,
/// `hardening.new_password`, any `*.passphrase`, etc. are all covered.
/// This is what makes the "no passwords on disk" guarantee an enforced
/// invariant rather than a convention.
bool isSecretDecisionKey(String key) {
  final segment = key.contains('.')
      ? key.substring(key.lastIndexOf('.') + 1)
      : key;
  return segment == 'password' ||
      segment == 'new_password' ||
      segment == 'passphrase' ||
      segment == 'secret';
}

/// Immutable snapshot of the wizard at a point in time.
///
/// Built on the pure-Dart [ForgeWizardState] so `deckhand_core` shares
/// the same flow/state/persistence engine as the Forge-family UI apps
/// without pulling in Flutter. The Deckhand-named surface (`profileId`,
/// `flow`, `currentStep`, the SSH triple) is layered on top as getters
/// over the neutral base fields (`subjectId`, `flowId`, `currentStepId`,
/// `connection`), so every existing call site keeps reading the names it
/// always has.
///
/// Only data the wizard owns goes here — no live SSH session, no
/// confirmation tokens, no passwords. The reason: this object is
/// the unit of resume persistence (see [WizardStateStore]), and
/// secrets durably written to disk would let a thief restoring a
/// prior session bypass authentication. The serializer therefore
/// only round-trips the decision graph + nav cursor + SSH endpoint.
class WizardState extends ForgeWizardState {
  WizardState({
    required String profileId,
    required super.decisions,
    required String currentStep,
    required WizardFlow flow,
    String? sshHost,
    int? sshPort,
    String? sshUser,
  }) : super(
         subjectId: profileId,
         currentStepId: currentStep,
         flowId: flow.name,
         connection: ForgeWizardConnection(
           host: sshHost,
           port: sshPort,
           user: sshUser,
         ),
       );

  factory WizardState.initial() => WizardState(
    profileId: '',
    decisions: const {},
    currentStep: 'welcome',
    flow: WizardFlow.none,
  );

  /// Round-trip the wizard state to/from JSON so the app can persist
  /// it between launches and resume after a crash. Delegates to the
  /// shared [ForgeWizardStateCodec] so the on-disk schema lives in one
  /// place. A null decode (schema mismatch / malformed) degrades to
  /// [WizardState.initial] — callers that need to distinguish "no valid
  /// snapshot" go through [WizardStateStore.load], which returns null.
  factory WizardState.fromJson(Map<String, dynamic> json) {
    final decoded = _wizardStateCodec.fromJson(json);
    if (decoded == null) return WizardState.initial();
    return wizardStateFromForge(decoded);
  }

  /// Deckhand-named view over the neutral [subjectId].
  String get profileId => subjectId;

  /// Deckhand-named view over the neutral [currentStepId].
  String get currentStep => currentStepId;

  /// Decode the neutral [flowId] string into the Deckhand [WizardFlow]
  /// enum. Unknown ids degrade to [WizardFlow.none].
  WizardFlow get flow => _flowFromId(flowId);

  String? get sshHost => connection.host;
  int? get sshPort => connection.port;
  String? get sshUser => connection.user;

  /// Serialize through the shared [ForgeWizardStateCodec] (one on-disk
  /// schema), then strip secret decisions (passwords/passphrases) so they
  /// never reach disk — see [isSecretDecisionKey]. Resume therefore
  /// re-prompts for them: a restored session can't replay a credential the
  /// user never re-entered.
  Map<String, dynamic> toJson() {
    final json = _wizardStateCodec.toJson(this);
    final decisions = json['decisions'];
    if (decisions is Map) {
      json['decisions'] = <String, Object?>{
        for (final entry in decisions.entries)
          if (!isSecretDecisionKey('${entry.key}')) '${entry.key}': entry.value,
      };
    }
    return json;
  }

  @override
  WizardState copyWith({
    String? profileId,
    Map<String, Object>? decisions,
    String? currentStep,
    WizardFlow? flow,
    Object? sshHost = _copyWithUnset,
    Object? sshPort = _copyWithUnset,
    Object? sshUser = _copyWithUnset,
    // Present only to satisfy the base `copyWith` override contract;
    // Deckhand call sites use the named fields above. When supplied
    // (e.g. by ForgeWizardFlowProcess), it is honored verbatim.
    String? subjectId,
    String? currentStepId,
    String? flowId,
    Object? connection = _copyWithUnset,
  }) {
    final base = super.copyWith(
      subjectId: profileId ?? subjectId,
      decisions: decisions,
      currentStepId: currentStep ?? currentStepId,
      flowId: flow?.name ?? flowId,
      connection: identical(connection, _copyWithUnset)
          ? this.connection.copyWith(
              host: sshHost,
              port: sshPort,
              user: sshUser,
            )
          : connection,
    );
    return wizardStateFromForge(base);
  }
}

/// On-disk persistence layer for [WizardState]. A thin Deckhand-named
/// adapter over the pure-Dart [ForgeWizardStateStore]: writes are atomic
/// (`<path>.tmp` → rename) and coalesce-to-latest so a flurry of
/// unawaited saves can't race the old state onto disk; resume loads are
/// best-effort (corrupt / out-of-schema files load as "no resume").
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
  WizardStateStore({required this.path, this.errorSink})
    : _delegate = ForgeWizardStateStore<WizardState>(
        path: path,
        codec: _wizardStateCodec,
        convert: wizardStateFromForge,
        errorSink: errorSink,
      );

  WizardStateStore._fromDelegate(this._delegate, this.path, this.errorSink);

  final String path;
  final void Function(Object error, StackTrace stackTrace)? errorSink;
  final ForgeWizardStateStore<WizardState> _delegate;

  Future<WizardState?> load() => _delegate.load();

  /// Schedule a save of [state]. Returns a future that completes when
  /// either this state or a later state that superseded it has been
  /// durably persisted. Safe to call unawaited — write errors are
  /// routed to [errorSink] rather than thrown back at the caller, so
  /// the wizard never blocks on a flaky disk.
  Future<void> save(WizardState state) => _delegate.save(state);

  Future<void> clear() => _delegate.clear();
}

/// Synchronous-resolving WizardStateStore backed by a single
/// in-memory slot. Widget tests use this so the post-frame
/// `_maybeOfferResume` callback never blocks on real `File` I/O —
/// the load/save futures complete on the next microtask, which the
/// test harness's frame pump can drain deterministically.
///
/// Wraps [InMemoryForgeWizardStateStore] so it satisfies the same
/// Deckhand [WizardStateStore] surface while sharing the forge engine's
/// in-memory semantics.
class InMemoryWizardStateStore extends WizardStateStore {
  InMemoryWizardStateStore({
    void Function(Object error, StackTrace stackTrace)? errorSink,
  }) : super._fromDelegate(
         InMemoryForgeWizardStateStore<WizardState>(
           codec: _wizardStateCodec,
           convert: wizardStateFromForge,
           errorSink: errorSink,
         ),
         '<memory>',
         errorSink,
       );
}
