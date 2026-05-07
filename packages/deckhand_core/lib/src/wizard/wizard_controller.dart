import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../models/printer_profile.dart';
import '../services/discovery_service.dart';
import '../services/elevated_helper_service.dart';
import '../services/flash_service.dart';
import '../services/moonraker_service.dart';
import '../services/profile_service.dart';
import '../services/archive_service.dart';
import '../services/security_service.dart';
import '../services/ssh_service.dart';
import '../services/upstream_service.dart';
import '../shell/shell_quoting.dart';
import 'dsl.dart';
import 'pending_input.dart';
import 'printer_state_probe.dart';
import 'run_state.dart';
import 'wizard_events.dart';
import 'wizard_flow.dart';
import 'wizard_state.dart';

// Re-exported so existing `package:deckhand_core/deckhand_core.dart`
// imports keep resolving WizardFlow / WizardState / WizardStateStore /
// WizardEvent / StepExecutionException without touching call sites.
export 'wizard_events.dart';
export 'wizard_flow.dart';
export 'wizard_state.dart';

// Method bodies for backup management (restoreBackup, readBackupContent,
// deleteBackup, pruneBackups) live in a separate file so the main
// controller stays navigable. They operate on this controller via
// library-private access because `part of` puts them in the same
// library as WizardController.
part 'wizard_controller_backup.dart';

// Long step-execution bodies (write_file, install_screen, flash_mcus,
// os_download, flash_disk, script + askpass) live in a separate file
// for the same reason. Same `part of` scope-sharing applies.
part 'wizard_controller_steps.dart';
part 'wizard_controller_install.dart';
part 'wizard_controller_helpers.dart';
part 'wizard_controller_runtime.dart';

/// Wizard state machine - profile-driven, UI-agnostic.
class WizardController {
  WizardController({
    required this.profiles,
    required this.ssh,
    required this.flash,
    required this.discovery,
    required this.moonraker,
    required this.upstream,
    required this.security,
    this.elevatedHelper,
    this.archive,
    this.snapshotsDir,
    this.osImagesDir,
    this.deckhandVersion = 'unknown',
  }) {
    _runStateStore = RunStateStore(ssh: ssh);
  }

  final ProfileService profiles;
  final SshService ssh;
  final FlashService flash;
  final DiscoveryService discovery;
  final MoonrakerService moonraker;
  final UpstreamService upstream;
  final SecurityService security;

  /// Optional: when non-null, raw-device writes go through the elevated
  /// helper (UAC / pkexec / osascript). Tests leave this null.
  final ElevatedHelperService? elevatedHelper;

  /// Optional: stock-config snapshot capture/restore (the S145 path).
  /// When null, `snapshot_archive` step kinds are surfaced as a
  /// StepWarning rather than failing — profiles with no snapshot
  /// step still install cleanly.
  final ArchiveService? archive;

  /// Where on the host to write captured snapshot archives. Production
  /// wiring sets this to `<data_dir>/state/snapshots/`. When null and
  /// a `snapshot_archive` step fires, the controller emits a warning
  /// and skips the capture.
  final String? snapshotsDir;

  /// Where on the host verified OS images are cached. Production
  /// wiring sets this to the sidecar-managed persistent cache root.
  /// When null, os_download falls back to its legacy temp directory.
  final String? osImagesDir;

  /// Surfaced into the on-printer run-state file's
  /// `deckhand_version` field so a maintainer reading a debug
  /// bundle can correlate the install attempt with a release.
  /// Production wiring fills this from CalVer; tests leave it as
  /// `unknown`, which is fine — the field is informational.
  final String deckhandVersion;

  late final RunStateStore _runStateStore;
  RunState? _runState;

  late final DslEvaluator _dsl = DslEvaluator(defaultPredicates());
  final _eventsController = StreamController<WizardEvent>.broadcast();
  final _pendingInput = PendingInputRegistry();

  PrinterProfile? _profile;
  ProfileCacheEntry? _profileCache;
  SshSession? _session;
  // Remembered so we can run `sudo -S` without allocating a pty. Not
  // persisted anywhere; dropped when the controller disposes.
  String? _sshPassword;
  // Set of askpass helpers staged this session, keyed by step id. The
  // first script step stages the helper; subsequent script steps reuse
  // it. Cleaned up all at once in `dispose()` so each script doesn't
  // pay the upload cost + the per-step cleanup race.
  _ScriptSudoHelper? _sessionAskpass;
  // The `kind:` of the step currently executing under `_runStep` (or
  // null when nothing is running / execution is complete). Read by
  // the stepper so it can switch its "Install" label to a more
  // specific phase label ("Writing image") during long-running steps.
  String? _currentStepKind;
  // Snapshot of what's actually present/running on this specific
  // printer. Populated by [probePrinterState]; screens read from it
  // to dim options that don't apply to THIS machine (service already
  // absent, file already deleted, etc.) even though the profile
  // declares them for the printer type.
  PrinterState _printerState = PrinterState.empty;
  var _state = WizardState.initial();

  WizardState get state => _state;
  PrinterProfile? get profile => _profile;
  String? get currentStepKind => _currentStepKind;
  PrinterState get printerState => _printerState;
  Stream<WizardEvent> get events => _eventsController.stream;

  /// Session values to feed [Redactor.sessionValues] when generating
  /// debug bundles. Includes the SSH password (when cached) so a
  /// short user-chosen password that wouldn't trip the entropy
  /// heuristic is still substituted out by exact-match. Callers from
  /// the UI shouldn't read these fields directly — go through this
  /// method so the surface stays narrow.
  Map<String, String?> redactionSessionValues() => {
    'printer_host': _state.sshHost,
    'ssh_user': _session?.user,
    'ssh_password': _sshPassword,
  };

  /// Live SSH session, if any. Set by [connectSsh] / [connectSshWithPassword]
  /// and cleared on disconnect. Screens that need to probe the printer
  /// outside of a step (e.g. the S145 snapshot size estimate) read this
  /// directly rather than holding their own copy. Returns null when no
  /// session is open — callers must handle this defensively.
  SshSession? get sshSession => _session;

  /// Test-only: inject a canned [PrinterState] so widget tests can
  /// exercise probe-driven UI branches without standing up an SSH
  /// session. Emits [PrinterStateRefreshed] so screens that watch
  /// [wizardStateProvider] rebuild in response.
  ///
  /// The setter body runs inside an `assert(() { ... return true; }())`
  /// wrapper so it's a silent no-op in profile / release builds - a
  /// contributor who accidentally calls this from production code on
  /// a release build gets no state change, never a misleading state
  /// update that could mask real bugs. `@visibleForTesting` stays as
  /// a linter hint on top of the runtime gate.
  @visibleForTesting
  set printerStateForTesting(PrinterState value) {
    assert(() {
      _printerState = value;
      _emit(PrinterStateRefreshed(value));
      return true;
    }());
  }

  /// Test-only: install a fake [SshSession] without going through the
  /// real `connectSsh` / `tryDefaults` path. Lets unit tests exercise
  /// install steps that require an active session without a real SSH
  /// stack. Same `assert(() {})` gating as
  /// [printerStateForTesting] so it's a silent no-op in release.
  @visibleForTesting
  void setSession(SshSession session) {
    assert(() {
      _session = session;
      _state = _state.copyWith(sshHost: session.host);
      return true;
    }());
  }

  /// Seed the controller from a persisted [WizardState] snapshot and
  /// reload the underlying profile so the wizard's screens have
  /// something to render against. The SSH session and all secrets
  /// (passwords, confirmation tokens) are deliberately NOT part of
  /// the snapshot, so resuming always lands the user on the connect
  /// screen with a re-prompt — never past an authentication gate.
  ///
  /// Throws [ResumeFailedException] (with the original cause attached
  /// and the snapshot still resident in `state` so the caller can
  /// retry or render an error UX) when the profile fails to reload.
  /// The previous behaviour of silently falling back to
  /// [WizardState.initial] threw away the user's session — that's
  /// worse than blank, so we now surface the failure loudly.
  Future<void> restore(WizardState snapshot) async {
    _state = snapshot;
    if (snapshot.profileId.isEmpty) {
      _emit(FlowChanged(_state.flow));
      return;
    }
    try {
      await loadProfile(snapshot.profileId);
      // loadProfile resets currentStep to whatever copyWith default
      // it picks. Re-apply the snapshot so the saved currentStep
      // wins — the user lands where they left off.
      _state = snapshot;
    } catch (e, st) {
      throw ResumeFailedException(snapshot: snapshot, cause: e, stackTrace: st);
    }
    _emit(FlowChanged(_state.flow));
  }

  /// Update the persisted `currentStep` (the wizard's nav cursor).
  /// Wired into the router so every navigation through GoRouter
  /// records where the user is, which keeps the on-disk snapshot's
  /// `currentStep` in sync with the screen actually showing. Without
  /// this the controller never updated `currentStep` past `'welcome'`
  /// and the resume panel always rendered "S10 · welcome" regardless
  /// of how deep the user got.
  ///
  /// No-ops when the new step matches the current value to avoid
  /// emitting redundant save events on rebuilds. Emits
  /// [FlowChanged] (the existing "wizard moved" event) so the
  /// `wizardStateProvider` stream picks it up and persists.
  void setCurrentStep(String step) {
    if (step.isEmpty || step == _state.currentStep) return;
    _state = _state.copyWith(currentStep: step);
    _emit(FlowChanged(_state.flow));
  }

  Future<void> loadProfile(
    String profileId, {
    String? ref,
    bool force = false,
  }) async {
    final cache = await profiles.ensureCached(
      profileId: profileId,
      ref: ref,
      force: force,
    );
    final profile = await profiles.load(cache);
    _profile = profile;
    _profileCache = cache;
    _state = _state.copyWith(profileId: profileId);
    _emit(ProfileLoaded(profile));
  }

  Future<void> connectSsh({
    required String host,
    int? port,
    bool acceptHostKey = false,
    String? acceptedHostFingerprint,
  }) async {
    final pf = _profile;
    if (pf == null) {
      throw StateError('Load a profile before connecting SSH.');
    }
    final creds = pf.ssh.defaultCredentials
        .map(
          (c) => PasswordCredential(user: c.user, password: c.password ?? ''),
        )
        .toList();
    final session = await ssh.tryDefaults(
      host: host,
      port: port ?? pf.ssh.defaultPort,
      credentials: creds.cast<SshCredential>(),
      acceptHostKey: acceptHostKey,
      acceptedHostFingerprint: acceptedHostFingerprint,
    );
    _session = session;
    // Remember the password of whichever default matched, so sudo
    // commands can feed it on stdin.
    for (final c in pf.ssh.defaultCredentials) {
      if (c.user == session.user && c.password != null) {
        _sshPassword = c.password;
        break;
      }
    }
    _state = _state.copyWith(sshHost: host);
    await _runStateAttachSession();
    _emit(SshConnected(host: host, user: session.user));
    // Fire the inventory probe in the background so the services /
    // files / screens screens render with machine-specific state
    // without making the user wait at the Connect step for it.
    // Probe failures emit StepWarning internally; the .catchError is a
    // belt-and-suspenders guard so a surprise sync throw at the top of
    // _refreshPrinterState never becomes an unhandled async error.
    unawaited(_refreshPrinterState().catchError((_) {}));
  }

  /// Connect with a specific username/password. Used as the fallback when
  /// the profile's default credentials don't authenticate (e.g. the user
  /// has changed the stock password).
  Future<void> connectSshWithPassword({
    required String host,
    int? port,
    required String user,
    required String password,
    bool acceptHostKey = false,
    String? acceptedHostFingerprint,
  }) async {
    final pf = _profile;
    final p = port ?? pf?.ssh.defaultPort ?? 22;
    final session = await ssh.connect(
      host: host,
      port: p,
      credential: PasswordCredential(user: user, password: password),
      acceptHostKey: acceptHostKey,
      acceptedHostFingerprint: acceptedHostFingerprint,
    );
    _session = session;
    _sshPassword = password;
    _state = _state.copyWith(sshHost: host);
    await _runStateAttachSession();
    _emit(SshConnected(host: host, user: session.user));
    // Probe failures emit StepWarning internally; the .catchError is a
    // belt-and-suspenders guard so a surprise sync throw at the top of
    // _refreshPrinterState never becomes an unhandled async error.
    unawaited(_refreshPrinterState().catchError((_) {}));
  }

  /// Re-run the state probe against the current SSH session. Emits
  /// [PrinterStateRefreshed] when fresh data lands so screens can
  /// rebuild. Called automatically on connect; screens can call it
  /// manually (via [refreshPrinterState]) after a user action that
  /// changes the printer state (e.g. after the install flow
  /// completes and you navigate back to adjust decisions).
  ///
  /// Freshness gate: a background probe finished within the last
  /// [_probeFreshness] skips. Wizard navigation that bounces users
  /// back/forward on option screens (/services -> /files -> /services)
  /// would otherwise re-probe every time, wasting bandwidth and the
  /// printer's CPU.
  static const _probeFreshness = Duration(seconds: 30);

  /// _refreshPrinterState dispatcher. Body in wizard_controller_runtime.dart.
  Future<void> _refreshPrinterState({bool force = false}) =>
      _refreshPrinterStateImpl(this, force: force);

  /// Public entry point for screens that want to trigger a re-probe.
  /// Pass `force: true` to bypass the freshness gate (e.g. after a
  /// restoreBackup so the backup list reflects the new state).
  Future<void> refreshPrinterState({bool force = false}) =>
      _refreshPrinterState(force: force);

  /// Restore a prior write_file auto-snapshot. Copies `backupPath`
  /// back over `originalPath` using sudo when the target is outside
  /// the SSH user's home. `cp -p` preserves the original's mode and
  /// ownership metadata that we captured at backup time - so the
  /// restored file matches what was there before Deckhand touched it.
  /// The backup file is LEFT in place after restore; callers can use
  /// [deleteBackup] to clean up once they're satisfied.
  /// Throws [StepExecutionException] on failure.
  /// Restore a prior `.deckhand-pre-*` backup over its original target.
  /// Implementation in wizard_controller_backup.dart.
  Future<void> restoreBackup(DeckhandBackup backup) =>
      _restoreBackupImpl(this, backup);

  /// Fetch the content of a backup file so the UI can show a preview
  /// before the user commits to restoring. Returns null on read
  /// failure (best-effort; the user can still restore without
  /// preview). Implementation in wizard_controller_backup.dart.
  ///
  /// Guards:
  ///   - 256 KiB byte cap so a big binary can't DoS the UI.
  ///   - 200-line cap; very-long single-line content (minified JSON,
  ///     one-liner configs) truncates at the line level too.
  ///   - Binary detection via layered probe; binary files return a
  ///     marker string rather than garbage.
  Future<String?> readBackupContent(DeckhandBackup backup) =>
      _readBackupContentImpl(this, backup);

  /// Decide if the probe output from the layered binary detector
  /// indicates a non-text file. See [readBackupContent] for the
  /// layering; this is the shared judgement function, kept pure so
  /// the unit test can pin the classification table.
  @visibleForTesting
  static bool looksLikeBinary(String probeOutput) =>
      _looksLikeBinary(probeOutput);

  /// _looksLikeBinary dispatcher. Body in wizard_controller_runtime.dart.
  static bool _looksLikeBinary(String s) => _looksLikeBinaryImpl(s);

  /// Delete a `.deckhand-pre-*` backup + its `.meta.json` sidecar.
  /// Used by the verify_screen after the user has confirmed they
  /// don't need the rollback snapshot anymore. Throws on failure.
  /// Implementation in wizard_controller_backup.dart.
  Future<void> deleteBackup(DeckhandBackup backup) =>
      _deleteBackupImpl(this, backup);

  /// Sweep all `.deckhand-pre-*` backups older than [olderThan] from
  /// the printer. When [keepLatestPerTarget] is true, the single
  /// newest backup for each `originalPath` is spared even when it
  /// would otherwise be in the victim set - useful as a safety net
  /// against "I pruned too aggressively and now have no snapshot of
  /// my sources.list."
  ///
  /// Returns the number of backup files removed (sidecars counted
  /// as part of the same logical backup). Implementation in
  /// wizard_controller_backup.dart.
  Future<int> pruneBackups({
    Duration olderThan = const Duration(days: 30),
    bool keepLatestPerTarget = false,
  }) => _pruneBackupsImpl(
    this,
    olderThan: olderThan,
    keepLatestPerTarget: keepLatestPerTarget,
  );

  Future<void> setDecision(String path, Object value) async {
    // Immutable map merge rather than Map.from() + mutate. Avoids any
    // possibility of two concurrent calls racing on the same temporary
    // mutable map while the copyWith is scheduled.
    _state = _state.copyWith(decisions: {..._state.decisions, path: value});
    _emit(DecisionRecorded(path: path, value: value));
  }

  T? decision<T>(String path) => _state.decisions[path] as T?;

  String resolveServiceDefault(StockService svc) {
    final rules =
        ((svc.raw['wizard'] as Map?)?['default_rules'] as List?) ?? const [];
    final env = _buildDslEnv();
    for (final r in rules.whereType<Map>().map(
      (m) => m.cast<String, dynamic>(),
    )) {
      final when = r['when'] as String?;
      final thenVal = r['then'] as String?;
      if (when == null || thenVal == null) continue;
      try {
        if (_dsl.evaluate(when, env)) return thenVal;
      } catch (_) {
        continue;
      }
    }
    return svc.defaultAction;
  }

  /// Build the DSL evaluation env with live probe results folded in
  /// as `probe.*` decision entries. Centralised so every DSL caller
  /// sees the same view of the printer - otherwise we'd leak the
  /// profile-declared "stock OS" assumptions into conditions that
  /// should be live-state-aware.
  DslEnv _buildDslEnv() {
    final decisions = Map<String, Object>.from(_state.decisions);
    final probe = _printerState;
    if (probe.osCodename != null) {
      decisions['probe.os_codename'] = probe.osCodename!;
    }
    if (probe.osId != null) {
      decisions['probe.os_id'] = probe.osId!;
    }
    if (probe.osVersionId != null) {
      decisions['probe.os_version_id'] = probe.osVersionId!;
    }
    if (probe.pythonDefaultVersion != null) {
      decisions['probe.python_default'] = probe.pythonDefaultVersion!;
    }
    // python3.11 presence lets os_python_below short-circuit to false
    // for any threshold <= 3.11 regardless of what the profile claims
    // the stock Python version is.
    if (probe.python311Installed) {
      decisions['probe.os_python_below.3.9'] = false;
      decisions['probe.os_python_below.3.10'] = false;
      decisions['probe.os_python_below.3.11'] = false;
    }
    return DslEnv(decisions: decisions, profile: _profile?.raw ?? const {});
  }

  void setFlow(WizardFlow flow) {
    _state = _state.copyWith(flow: flow);
    _emit(FlowChanged(flow));
  }

  /// Resolve an outstanding user-input request. UI code calls this when
  /// the user has made a decision for a UI-driven step.
  void resolveUserInput(String stepId, Object? value) =>
      _pendingInput.resolve(stepId, value);

  bool _cancelled = false;
  String? _cancelReason;

  /// Abort the in-flight [startExecution] cleanly. The current step
  /// finishes (or its `await` completes), then the loop bails before
  /// dispatching the next step with a [WizardCancelledException].
  /// Idempotent — second call has no extra effect.
  ///
  /// Used by the HITL driver when a step fires [UserInputRequired]
  /// without the scenario having pre-decided the answer; production
  /// flows would call this from a "Cancel install" button on S900.
  void cancelExecution({String reason = 'cancelled'}) {
    if (_cancelled) return;
    _cancelled = true;
    _cancelReason = reason;
    _pendingInput.clear();
  }

  /// Public entrypoint - walks the active flow. Body in
  /// wizard_controller_runtime.dart so the controller stays under
  /// the project's line-count ceiling.
  Future<void> startExecution() => _startExecutionImpl(this);

  /// Initialise [_runState] for the active session. Best-effort:
  /// tolerates "no SSH yet", "file missing", "file unparseable".
  /// Run-state dispatchers. Bodies in wizard_controller_runtime.dart.
  Future<void> _runStateBootstrap() => _runStateBootstrapImpl(this);
  Future<void> _runStateAttachSession() => _runStateAttachSessionImpl(this);
  Future<void> _runStateRecord(RunStateStep step) =>
      _runStateRecordImpl(this, step);

  /// _canonicalStepInputs dispatcher. Body in wizard_controller_runtime.dart.
  Map<String, Object?> _canonicalStepInputs(Map<String, dynamic> step) =>
      _canonicalStepInputsImpl(this, step);

  Future<void> _runStep(Map<String, dynamic> step) async {
    final kind = step['kind'] as String? ?? '';
    final id = step['id'] as String? ?? '';
    switch (kind) {
      case 'ssh_commands':
        await _runSshCommands(step);
      case 'snapshot_paths':
        await _runSnapshotPaths(step);
      case 'snapshot_archive':
        await _runSnapshotArchive(step);
      case 'install_firmware':
        await _runInstallFirmware(step);
      case 'link_extras':
        await _runLinkExtras(step);
      case 'install_stack':
        await _runInstallStack(step);
      case 'apply_services':
        await _runApplyServices(step);
      case 'apply_files':
        await _runApplyFiles(step);
      case 'write_file':
        await _runWriteFile(step);
      case 'install_screen':
        await _runInstallScreen(step);
      case 'flash_mcus':
        await _runFlashMcus(step);
      case 'os_download':
        await _runOsDownload(step);
      case 'flash_disk':
        await _runFlashDisk(step);
      case 'wait_for_ssh':
        await _runWaitForSsh(step);
      case 'verify':
        await _runVerify(step);
      case 'conditional':
        await _runConditional(step);
      case 'prompt':
        // `backup_prompt` historically asked the user mid-install
        // whether they had a full eMMC backup, but the dialog never
        // triggered an actual backup — it just recorded the answer.
        // The eMMC-backup acknowledgement now lives at S145-snapshot
        // (one consolidated decision), so suppressing this step here
        // keeps the backstop in place for older cached profiles that
        // still carry the legacy `backup_prompt` declaration. Logged
        // at WARN level so a profile author who genuinely needs a
        // mid-install prompt notices.
        if (id == 'backup_prompt') {
          _emit(
            StepWarning(
              stepId: id,
              message:
                  'backup_prompt suppressed (consolidated into S145 '
                  'snapshot screen). Update the profile to remove this '
                  'step.',
            ),
          );
          break;
        }
        await _awaitUserInput(id, step);
      case 'choose_one':
      case 'disk_picker':
        await _resolveOrAwaitInput(id, step);
      case 'script':
        await _runScript(step);
      case 'install_marker':
        await _runInstallMarker(step);
      default:
        _emit(
          StepWarning(
            stepId: id,
            message: 'Unknown step kind "$kind" - skipping',
          ),
        );
    }
  }

  /// Step dispatchers. Bodies in wizard_controller_runtime.dart.
  Future<void> _runSshCommands(Map<String, dynamic> step) =>
      _runSshCommandsImpl(this, step);
  Future<void> _runSnapshotPaths(Map<String, dynamic> step) =>
      _runSnapshotPathsImpl(this, step);

  /// Capture the user's S145-selected paths into a host-local
  /// `.tar.gz`. The user's selection lives at
  /// `_state.decisions['snapshot.paths']` (a list of snapshot-path
  /// IDs); we resolve each ID against `profile.stockOs.snapshotPaths`
  /// to get the actual on-printer path, then stream the archive home
  /// via [ArchiveService.captureRemote].
  ///
  /// Failure modes:
  ///   - No archive service wired: warn + skip (profile installs work
  ///     without snapshots; the user just doesn't get a config backup).
  ///   - No paths declared / no IDs selected: warn + skip.
  ///   - Capture fails: hard error so the user sees it before the
  ///     install rewrites their config.
  /// snapshot_archive step dispatcher. Body in wizard_controller_runtime.dart.
  Future<void> _runSnapshotArchive(Map<String, dynamic> step) =>
      _runSnapshotArchiveImpl(this, step);

  /// install_firmware step dispatcher. Body in wizard_controller_install.dart.
  Future<void> _runInstallFirmware(Map<String, dynamic> step) =>
      _runInstallFirmwareImpl(this, step);

  /// link_extras step dispatcher. Body in wizard_controller_install.dart.
  Future<void> _runLinkExtras(Map<String, dynamic> step) =>
      _runLinkExtrasImpl(this, step);

  /// install_stack step dispatcher. Body in wizard_controller_install.dart.
  Future<void> _runInstallStack(Map<String, dynamic> step) =>
      _runInstallStackImpl(this, step);

  /// apply_services step dispatcher. Body in wizard_controller_install.dart.
  Future<void> _runApplyServices(Map<String, dynamic> step) =>
      _runApplyServicesImpl(this, step);

  /// apply_files step dispatcher. Body in wizard_controller_install.dart.
  Future<void> _runApplyFiles(Map<String, dynamic> step) =>
      _runApplyFilesImpl(this, step);

  bool _hasGlob(String path) => RegExp(r'[*?\[]').hasMatch(path);

  /// write_file step dispatcher. Body in wizard_controller_steps.dart.
  Future<void> _runWriteFile(Map<String, dynamic> step) =>
      _runWriteFileImpl(this, step);

  bool _looksLikeSystemPath(SshSession s, String target) {
    // Anything under the login user's home (and /tmp) is writable
    // without elevation; everything else we assume needs sudo.
    if (target.startsWith('/home/${s.user}/')) return false;
    // root's home is /root on every distro Deckhand targets; the
    // generic /home/<user>/ check misses it otherwise.
    if (s.user == 'root' && target.startsWith('/root/')) return false;
    if (target.startsWith('/tmp/')) return false;
    return true;
  }

  /// install_screen step dispatcher. Body in wizard_controller_steps.dart.
  Future<void> _runInstallScreen(Map<String, dynamic> step) =>
      _runInstallScreenImpl(this, step);

  /// flash_mcus step dispatcher. Body in wizard_controller_steps.dart.
  Future<void> _runFlashMcus(Map<String, dynamic> step) =>
      _runFlashMcusImpl(this, step);

  /// os_download step dispatcher. Body in wizard_controller_steps.dart.
  Future<void> _runOsDownload(Map<String, dynamic> step) =>
      _runOsDownloadImpl(this, step);

  /// flash_disk step dispatcher. Body in wizard_controller_steps.dart.
  Future<void> _runFlashDisk(Map<String, dynamic> step) =>
      _runFlashDiskImpl(this, step);

  /// script step dispatcher. Body in wizard_controller_steps.dart.
  Future<void> _runScript(Map<String, dynamic> step) =>
      _runScriptImpl(this, step);

  /// install_marker step dispatcher. Body in wizard_controller_runtime.dart.
  Future<void> _runInstallMarker(Map<String, dynamic> step) =>
      _runInstallMarkerImpl(this, step);

  /// Resolve-or-await input dispatcher. Body in wizard_controller_runtime.dart.
  Future<void> _resolveOrAwaitInput(String id, Map<String, dynamic> step) =>
      _resolveOrAwaitInputImpl(this, id, step);

  /// wait_for_ssh step dispatcher. Body in wizard_controller_runtime.dart.
  Future<void> _runWaitForSsh(Map<String, dynamic> step) =>
      _runWaitForSshImpl(this, step);

  /// verify step dispatcher. Body in wizard_controller_runtime.dart.
  Future<void> _runVerify(Map<String, dynamic> step) =>
      _runVerifyImpl(this, step);

  /// conditional step dispatcher. Body in wizard_controller_runtime.dart.
  Future<void> _runConditional(Map<String, dynamic> step) =>
      _runConditionalImpl(this, step);

  Future<Object?> _awaitUserInput(String id, Map<String, dynamic> step) =>
      _pendingInput.awaitInput(id, step, _emit);

  /// Runs [command] over SSH. If [command] starts with `sudo`,
  /// `/usr/bin/sudo`, or `/bin/sudo` and we have a cached password
  /// for the session, strips that sudo word and delegates to
  /// [SshService.run] with `sudoPassword`. The SshService then wraps
  /// in `echo <pw> | sudo -S ...`, so sudo reads the password on stdin
  /// without needing a pty.
  ///
  /// Commands that START with a `KEY=value` env assignment (e.g. the
  /// askpass-wrapped `SUDO_ASKPASS=... sudo -A -E ...` form built by
  /// `_runScript`) are intentionally NOT stripped: we already routed
  /// auth through askpass, and combining `-S` with `-A` varies by sudo
  /// version. Anything without a sudo at position zero runs as-is.
  /// _runSsh dispatcher. Body in wizard_controller_helpers.dart.
  Future<SshCommandResult> _runSsh(
    String command, {
    Duration timeout = const Duration(seconds: 30),
  }) => _runSshImpl(this, command, timeout: timeout);

  SshSession _requireSession() {
    final s = _session;
    if (s == null) throw StepExecutionException('SSH not connected');
    return s;
  }

  FirmwareChoice? _selectedFirmware() {
    final id = _state.decisions['firmware'] as String?;
    if (id == null) return null;
    for (final c in _profile?.firmware.choices ?? const <FirmwareChoice>[]) {
      if (c.id == id) return c;
    }
    return null;
  }

  Map<String, dynamic>? _stackComponent(StackConfig stack, String name) {
    switch (name) {
      case 'moonraker':
        return stack.moonraker;
      case 'kiauh':
        return stack.kiauh;
      case 'crowsnest':
        return stack.crowsnest;
      default:
        final choices = ((stack.webui?['choices'] as List?) ?? const [])
            .cast<Map>();
        for (final c in choices) {
          if ((c['id'] as String?) == name) return c.cast<String, dynamic>();
        }
        return null;
    }
  }

  /// Helper dispatchers. Bodies in wizard_controller_helpers.dart.
  String _resolveProfilePath(String ref) => _resolveProfilePathImpl(this, ref);
  Future<void> _uploadDir(String localDir, String remote) =>
      _uploadDirImpl(this, localDir, remote);
  String _mcuConfig(Map<String, dynamic> mcu) => _mcuConfigImpl(mcu);
  bool _isDangerousPath(String path) => _isDangerousPathImpl(path);
  String _shellQuote(String s) => shellSingleQuote(s);
  String _randomSuffix() => _randomSuffixImpl();
  String _buildEnvPrefix(Object? rawEnv) => _buildEnvPrefixImpl(rawEnv);
  void _validateRemoteInstallPath(String value, String label) =>
      _validateRemoteInstallPathImpl(value, label);
  String _safeRemoteBasename(String value, String label) =>
      _safeRemoteBasenameImpl(value, label);
  String _render(String template, {bool shellSafe = false}) =>
      _renderImpl(this, template, shellSafe: shellSafe);

  void _log(Map<String, dynamic> step, String line) {
    _emit(StepLog(stepId: step['id'] as String? ?? '', line: line));
  }

  void _emit(WizardEvent e) => _eventsController.add(e);

  Future<void> dispose() async {
    // Scrub the session askpass helper *before* tearing down the SSH
    // session so the password file doesn't linger on /tmp until the
    // next reboot. Best-effort: a broken connection here shouldn't
    // break disposal.
    final helper = _sessionAskpass;
    final session = _session;
    if (helper != null && session != null) {
      try {
        await ssh.run(
          session,
          'rm -rf '
          '${_shellQuote(helper.askpassPath)} '
          '${_shellQuote(helper.binDir)}',
        );
      } catch (_) {}
      _sessionAskpass = null;
    }
    await _eventsController.close();
    if (_session != null) await ssh.disconnect(_session!);
    // Overwrite then drop the cached SSH password so the GC has no
    // reason to hold onto its backing string. Dart strings are
    // immutable so this is a best-effort hint, not a guarantee.
    _sshPassword = null;
    _session = null;
    _pendingInput.clear();
  }
}

/// Paths to transient sudo helper assets a script step staged on the
/// remote printer. Returned from [_installSudoAskpassHelper] so the
/// caller's `finally` block can clean them up again.
class _ScriptSudoHelper {
  const _ScriptSudoHelper({required this.askpassPath, required this.binDir});
  final String askpassPath;
  final String binDir;
}

// WizardState and WizardStateStore have been extracted to their own
// file (wizard_state.dart) and are re-exported at the top of this
// library so existing imports continue to resolve.

// WizardEvent hierarchy and StepExecutionException have been
// extracted to wizard_events.dart and re-exported at the top of this
// file.
