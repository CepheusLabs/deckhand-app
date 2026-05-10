// Per-step runtime bodies (ssh_commands, snapshot, verify, marker,
// wait_for_ssh, conditional, run-state record/bootstrap) split out of
// wizard_controller.dart so the main controller stays under the
// project's 800-line ceiling. Top-level private helpers; share scope
// because this file is `part of 'wizard_controller.dart'`.
part of 'wizard_controller.dart';

/// Probe the printer's live state and emit [PrinterStateRefreshed].
/// Best-effort; failures emit a [StepWarning] rather than throwing,
/// so screens fall back to abstract option lists.
Future<void> _refreshPrinterStateImpl(
  WizardController c, {
  bool force = false,
}) async {
  final s = c._session;
  final pf = c._profile;
  if (s == null || pf == null) return;
  if (!force) {
    final last = c._printerState.probedAt;
    if (last != null &&
        DateTime.now().difference(last) < WizardController._probeFreshness) {
      return;
    }
  }
  try {
    final probe = PrinterStateProbe(ssh: c.ssh);
    final report = await probe.probe(session: s, profile: pf);
    if (!identical(c._session, s) || !identical(c._profile, pf)) return;
    c._printerState = report;
    c._emit(PrinterStateRefreshed(report));
  } catch (e) {
    c._emit(
      StepWarning(
        stepId: 'printer_state_probe',
        message: 'Could not probe printer state: $e',
      ),
    );
  }
}

/// Build the canonical-input map for a step. See WizardController for
/// the resolution-order docs; the body lives here so the controller
/// stays under the project's line-count ceiling.
Map<String, Object?> _canonicalStepInputsImpl(
  WizardController c,
  Map<String, dynamic> step,
) {
  final declared = step['idempotency'];
  if (declared is Map && declared['inputs'] is Map) {
    return _objectMap(declared['inputs']);
  }
  final base = <String, Object?>{'kind': step['kind'], 'id': step['id']};
  if (step['decision_keys'] is List) {
    for (final key in (step['decision_keys'] as List)) {
      base['decision.$key'] = c._state.decisions[key.toString()];
    }
    return base;
  }
  // Fall through: include the entire decision graph. Sorted
  // canonicalisation (in canonicalInputBytes) makes the order
  // irrelevant, so two runs with identical decisions produce
  // identical hashes.
  base['decisions'] = c._state.decisions;
  return base;
}

/// Decide if the probe output from the layered binary detector
/// indicates a non-text file. Pure function; the unit test pins the
/// classification table by calling [WizardController.looksLikeBinary]
/// (the public testing handle).
bool _looksLikeBinaryImpl(String s) {
  if (s.isEmpty) return false;
  final lower = s.toLowerCase();
  // Layer A signals (from `file --mime`).
  if (lower.contains('charset=binary')) return true;
  const binaryMimePrefixes = [
    'application/octet-stream',
    'application/x-executable',
    'application/x-sharedlib',
    'application/x-pie-executable',
    'application/x-mach-binary',
    'application/x-dosexec',
    'application/zip',
    'application/gzip',
    'application/x-tar',
    'application/x-xz',
    'application/x-bzip2',
    'application/x-7z-compressed',
    'application/vnd.ms-cab-compressed',
    'image/',
    'video/',
    'audio/',
  ];
  for (final p in binaryMimePrefixes) {
    if (lower.contains(p)) return true;
  }
  // Layer B signals (from plain `file -b`).
  const binaryKeywords = [
    'elf ',
    'executable',
    'shared object',
    'archive',
    'image data',
    'compiled',
    'compressed',
    'binary',
  ];
  for (final k in binaryKeywords) {
    if (lower.contains(k)) return true;
  }
  // `data` appears on its own line as busybox's catchall for
  // "couldn't classify, probably binary" - match it as a word, not a
  // substring (so "metadata" / "data-driven" in real text don't
  // falsely trip).
  if (RegExp(r'(^|\s|,)data(\s|,|$)').hasMatch(lower)) return true;
  // Layer C: od output contains `\0` glyphs for null bytes. od -An
  // -c renders NUL as `\0`. Count them - a handful in 512 bytes is
  // a strong "binary" signal for text-mostly files too.
  final nulCount = RegExp(r'\\0').allMatches(s).length;
  if (nulCount >= 3) return true;
  return false;
}

/// Public entrypoint body. Walks the active flow's steps, recording
/// each into run-state and dispatching via _runStep. The kind switch
/// itself stays in the controller.
Future<void> _startExecutionImpl(WizardController c) async {
  final pf = c._profile;
  if (pf == null) throw StateError('No profile loaded.');
  c._cancelled = false;
  c._cancelReason = null;
  final flow = c._state.flow == WizardFlow.stockKeep
      ? pf.flows.stockKeep
      : pf.flows.freshFlash;
  if (flow == null || !flow.enabled) {
    throw StateError('Flow ${c._state.flow} is not enabled for this profile.');
  }

  // Bootstrap run-state. Loading first lets a re-run on the same
  // printer pick up the prior history; if there's no SSH session
  // yet (some flows reach startExecution before connect — e.g.
  // fresh_flash, where connect happens mid-flow at S240), we'll
  // start an empty state in memory and writes are a no-op until
  // a session arrives via [_runStateAttachSession]. The store
  // itself is tolerant of "no file yet" as well.
  await c._runStateBootstrap();

  for (final step in flow.steps) {
    if (c._cancelled) {
      throw WizardCancelledException(c._cancelReason ?? 'cancelled');
    }
    final id = _stringValue(step['id']) ?? 'unnamed';
    final kind = _stringValue(step['kind']) ?? '';
    c._currentStepKind = kind;
    final hash = canonicalInputHash(c._canonicalStepInputs(step));
    final prior = c._runState?.lastFor(id);
    if (prior != null &&
        prior.status == RunStateStatus.completed &&
        prior.inputHash == hash) {
      if (await _runStateCanSkipCompletedStep(c, step)) {
        c._log(step, '[run-state] skipping $id; already completed');
        c._emit(StepCompleted(id));
        c._currentStepKind = null;
        continue;
      }
    }
    if (prior != null && prior.status == RunStateStatus.inProgress) {
      await _prepareInterruptedStepForRestart(c, step);
    }
    c._emit(StepStarted(id));
    await c._runStateRecord(
      RunStateStep(
        id: id,
        status: RunStateStatus.inProgress,
        startedAt: DateTime.now().toUtc(),
        inputHash: hash,
      ),
    );
    try {
      await c._runStep(step);
      await _runIdempotencyPostCheck(c, step);
      if (c._cancelled) {
        throw WizardCancelledException(c._cancelReason ?? 'cancelled');
      }
      c._emit(StepCompleted(id));
      await c._runStateRecord(
        RunStateStep(
          id: id,
          status: RunStateStatus.completed,
          startedAt:
              c._runState?.lastFor(id)?.startedAt ?? DateTime.now().toUtc(),
          finishedAt: DateTime.now().toUtc(),
          inputHash: hash,
        ),
      );
    } on WizardHandoffRequiredException {
      rethrow;
    } catch (e) {
      c._emit(StepFailed(stepId: id, error: '$e'));
      await c._runStateRecord(
        RunStateStep(
          id: id,
          status: RunStateStatus.failed,
          startedAt:
              c._runState?.lastFor(id)?.startedAt ?? DateTime.now().toUtc(),
          finishedAt: DateTime.now().toUtc(),
          inputHash: hash,
          error: '$e',
        ),
      );
      rethrow;
    } finally {
      c._currentStepKind = null;
    }
  }
  c._emit(const ExecutionCompleted());
}

Future<void> _prepareInterruptedStepForRestart(
  WizardController c,
  Map<String, dynamic> step,
) async {
  final id = _stringValue(step['id']) ?? 'unnamed';
  final idempotency = _idempotencyBlock(step);
  final resume = idempotency?['resume']?.toString();
  if (resume == 'cleanup_then_restart') {
    final cleanup = idempotency?['cleanup'];
    if (cleanup is! String || cleanup.trim().isEmpty) {
      throw StepExecutionException(
        'resume cleanup missing for interrupted step $id',
      );
    }
    c._requireSession();
    final rendered = c._render(cleanup, shellSafe: true);
    c._log(step, '[run-state] cleaning up interrupted step $id');
    final result = await c._runSsh(rendered);
    if (!result.success) {
      throw StepExecutionException(
        'cleanup failed before retrying $id',
        stderr: result.stderr,
      );
    }
    return;
  }
  if (resume == 'continue') {
    throw StepExecutionException(
      'resume=continue is not implemented for interrupted step $id',
    );
  }
}

const _interactiveRunStateStepKinds = <String>{
  'prompt',
  'choose_one',
  'disk_picker',
};

Map<String, dynamic>? _idempotencyBlock(Map<String, dynamic> step) {
  final raw = step['idempotency'];
  return _stringKeyMap(raw);
}

Future<bool> _runStateCanSkipCompletedStep(
  WizardController c,
  Map<String, dynamic> step,
) async {
  final id = _stringValue(step['id']) ?? 'unnamed';
  final kind = _stringValue(step['kind']) ?? '';
  final idempotency = _idempotencyBlock(step);
  final preCheck = idempotency?['pre_check'];
  if (preCheck is String && preCheck.trim().isNotEmpty) {
    c._requireSession();
    final rendered = c._render(preCheck, shellSafe: true);
    final result = await c._runSsh(rendered);
    if (result.success) {
      c._log(step, '[run-state] pre-check passed for $id');
      return true;
    }
    c._log(step, '[run-state] pre-check failed for $id; re-running');
    return false;
  }
  if (_interactiveRunStateStepKinds.contains(kind)) {
    return true;
  }
  c._emit(
    StepWarning(
      stepId: id,
      message:
          'Completed run-state exists, but this step has no idempotency '
          'pre-check; re-running it.',
    ),
  );
  return false;
}

Future<void> _runIdempotencyPostCheck(
  WizardController c,
  Map<String, dynamic> step,
) async {
  final idempotency = _idempotencyBlock(step);
  final postCheck = idempotency?['post_check'];
  if (postCheck is! String || postCheck.trim().isEmpty) return;
  c._requireSession();
  final rendered = c._render(postCheck, shellSafe: true);
  final result = await c._runSsh(rendered);
  if (result.success) {
    c._log(step, '[run-state] post-check passed');
    return;
  }
  throw StepExecutionException(
    'post-check failed for ${step['id'] ?? 'unnamed'}',
    stderr: result.stderr,
  );
}

/// Tolerant of "no SSH yet", "file missing", "file unparseable".
Future<void> _runStateBootstrapImpl(WizardController c) async {
  final pf = c._profile;
  final cache = c._profileCache;
  final session = c._session;
  final fresh = RunState.empty(
    deckhandVersion: c.deckhandVersion,
    profileId: pf?.id ?? '',
    profileCommit: cache?.resolvedSha ?? '',
  );
  if (session == null) {
    c._runState = fresh;
    return;
  }
  try {
    c._runState = await c._runStateStore.load(session) ?? fresh;
  } on Object {
    c._runState = fresh;
  }
}

Future<void> _runStateAttachSessionImpl(WizardController c) async {
  final session = c._session;
  if (session == null) return;
  final current = c._runState;
  try {
    final remote = await c._runStateStore.load(session);
    if (remote == null) return;
    c._runState = current == null ? remote : current.merging(remote);
  } on Object {
    return;
  }
}

/// Persist [step] into the run-state file. Errors are swallowed
/// (logged via StepWarning) — a transient SSH glitch must not abort
/// the install. The next successful write replays the full state, so
/// a missed write is recoverable.
Future<void> _runStateRecordImpl(WizardController c, RunStateStep step) async {
  final state = c._runState;
  final session = c._session;
  if (state == null || session == null) return;
  final next = state.upsertingLast(step);
  c._runState = next;
  try {
    await c._runStateStore.save(session, next);
  } on Object catch (e) {
    c._emit(
      StepWarning(
        stepId: step.id,
        message: 'run-state write failed (continuing): $e',
      ),
    );
  }
}

Future<void> _runSshCommandsImpl(
  WizardController c,
  Map<String, dynamic> step,
) async {
  c._requireSession();
  final commands = _stringList(step['commands']);
  final ignore = _boolValue(step['ignore_errors']);
  for (final cmd in commands) {
    // Substituted values (decisions, firmware fields, profile values)
    // are untrusted input reaching a shell. Render in shell-safe mode
    // so every substitution is single-quoted for its argument context.
    final rendered = c._render(cmd, shellSafe: true);
    final res = await c._runSsh(rendered);
    c._log(step, '[ssh] $rendered -> exit ${res.exitCode}');
    if (!res.success && !ignore) {
      throw StepExecutionException(
        'Command failed: $rendered',
        stderr: res.stderr,
      );
    }
  }
}

Future<void> _runSnapshotPathsImpl(
  WizardController c,
  Map<String, dynamic> step,
) async {
  c._requireSession();
  final pathIds = _stringList(step['paths']);
  final ts = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
  for (final id in pathIds) {
    final path = c._profile!.stockOs.paths.firstWhere(
      (x) => x.id == id,
      orElse: () => throw StepExecutionException('path "$id" not in profile'),
    );
    final snapshotTo = (path.snapshotTo ?? '${path.path}.stock.{{timestamp}}')
        .replaceAll('{{timestamp}}', ts);
    final rendered = c._render(snapshotTo);
    // Both source and destination come from untrusted profile/decision
    // values - quote every interpolation to prevent shell injection.
    final qSrc = shellSingleQuote(path.path);
    final qDst = shellSingleQuote(rendered);
    final cmd = 'if [ -e $qSrc ]; then mv $qSrc $qDst; fi';
    final res = await c._runSsh(cmd);
    c._log(step, '[snapshot] ${path.path} -> $rendered (exit ${res.exitCode})');
    if (!res.success) {
      throw StepExecutionException(
        'snapshot failed for ${path.path}',
        stderr: res.stderr,
      );
    }
  }
}

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
Future<void> _runSnapshotArchiveImpl(
  WizardController c,
  Map<String, dynamic> step,
) async {
  c._requireSession();
  final svc = c.archive;
  final dir = c.snapshotsDir;
  if (svc == null || dir == null) {
    c._emit(
      StepWarning(
        stepId: _stringValue(step['id']) ?? 'snapshot_archive',
        message:
            'archive service not wired; skipping snapshot capture '
            '(install will proceed but config backup is your problem)',
      ),
    );
    return;
  }
  final pf = c._profile;
  if (pf == null) throw StateError('no profile loaded');
  final selectedIds = _stringList(c._state.decisions['snapshot.paths']);
  if (selectedIds.isEmpty) {
    c._emit(
      StepWarning(
        stepId: _stringValue(step['id']) ?? 'snapshot_archive',
        message: 'no snapshot paths selected; nothing to archive',
      ),
    );
    return;
  }
  final byId = {for (final pp in pf.stockOs.snapshotPaths) pp.id: pp};
  final paths = <String>[];
  for (final id in selectedIds) {
    final pp = byId[id];
    if (pp == null) {
      c._emit(
        StepWarning(
          stepId: _stringValue(step['id']) ?? 'snapshot_archive',
          message: 'snapshot id "$id" not in profile; ignoring',
        ),
      );
      continue;
    }
    paths.add(pp.path);
  }
  if (paths.isEmpty) return;

  final tsLabel = DateTime.now()
      .toUtc()
      .toIso8601String()
      .replaceAll(':', '-')
      .split('.')
      .first;
  final session = c._session!;
  final archivePath = p.join(dir, '${pf.id}-$tsLabel.tar.gz');

  var totalBytes = 0;
  await for (final progress in svc.captureRemote(
    session: session,
    paths: paths,
    archivePath: archivePath,
  )) {
    totalBytes = progress.bytesCaptured;
    c._emit(
      StepProgress(
        stepId: _stringValue(step['id']) ?? 'snapshot_archive',
        percent: 0,
        message:
            '${(progress.bytesCaptured / 1024).toStringAsFixed(0)} KiB captured',
      ),
    );
  }
  final sha = await svc.archiveSha256(archivePath);
  c._log(
    step,
    '[snapshot_archive] wrote $archivePath ($totalBytes bytes, sha256=$sha)',
  );
  // Surface the archive path back into wizard state so the
  // post-install restore step (and the debug-bundle assembler)
  // can reference it.
  c._state = c._state.copyWith(
    decisions: {
      ...c._state.decisions,
      'snapshot.archive_path': archivePath,
      'snapshot.archive_sha256': sha,
    },
  );
}

Future<void> _runInstallMarkerImpl(
  WizardController c,
  Map<String, dynamic> step,
) async {
  c._requireSession();
  final pf = c._profile;
  if (pf == null) throw StepExecutionException('no profile loaded');
  final filename = _stringValue(step['filename']) ?? 'deckhand.json';
  final targetDir =
      _stringValue(step['target_dir']) ??
      '/home/${c._session!.user}/printer_data/config';
  final extra = _stringKeyMap(step['extra']) ?? const {};

  final payload = <String, dynamic>{
    'profile_id': pf.id,
    'profile_version': pf.version,
    'display_name': pf.displayName,
    'installed_at': DateTime.now().toUtc().toIso8601String(),
    'deckhand_schema': 1,
    ...extra,
  };
  final json = const JsonEncoder.withIndent('  ').convert(payload);
  final target = '$targetDir/$filename';

  // Ensure the config dir exists (fresh installs may not have laid
  // out printer_data yet). Use plain ssh.run, not _runSsh - we don't
  // want sudo wrapping.
  final mkdir = await c.ssh.run(
    c._requireSession(),
    'mkdir -p ${c._shellQuote(targetDir)}',
  );
  if (!mkdir.success) {
    throw StepExecutionException(
      'could not create $targetDir',
      stderr: mkdir.stderr,
    );
  }

  // Route through _runWriteFile so `deckhand.json` gets the same
  // auto-backup + metadata-sidecar treatment as every other
  // destructive write. Users who hand-edited the marker (to add
  // notes, pin a specific deckhand_schema, etc.) get a byte-exact
  // rollback.
  final syntheticStep = <String, dynamic>{
    'id': _stringValue(step['id']) ?? 'install_marker',
    'kind': 'write_file',
    'target': target,
    'content': json,
    'mode': '0644',
    'backup': step['backup'] is bool ? step['backup'] : true,
  };
  await c._runWriteFile(syntheticStep);
  c._log(step, '[marker] wrote $target (${json.length} bytes)');
}

/// For `choose_one` / `disk_picker` steps: if a pre-wizard screen
/// already recorded the decision, emit the resolution and move on;
/// otherwise fall back to awaiting user input.
Future<void> _resolveOrAwaitInputImpl(
  WizardController c,
  String id,
  Map<String, dynamic> step,
) async {
  final existing = _lookupExistingDecisionImpl(c, step);
  if (existing != null) {
    final display = await _displayExistingDecisionImpl(c, step, existing);
    c._log(step, '[input] using existing decision: $display');
    c._emit(DecisionRecorded(path: id, value: existing));
    return;
  }
  await c._awaitUserInput(id, step);
}

Future<String> _displayExistingDecisionImpl(
  WizardController c,
  Map<String, dynamic> step,
  Object existing,
) async {
  final kind = _stringValue(step['kind']) ?? '';
  if (kind == 'disk_picker' && existing is String) {
    return _userFacingDiskNameForIdImpl(c, existing);
  }
  return '$existing';
}

/// Checks known decision keys that may already hold the answer for
/// this step. Keeps the controller in sync with the pre-wizard
/// screens (flash_target_screen, choose_os_screen) without hardcoding
/// their step ids in the profile.
Object? _lookupExistingDecisionImpl(
  WizardController c,
  Map<String, dynamic> step,
) {
  final kind = _stringValue(step['kind']) ?? '';
  final optionsFrom = _stringValue(step['options_from']);
  final id = _stringValue(step['id']) ?? '';

  // Most specific first: step id.
  final byId = c._state.decisions[id];
  if (byId != null) return byId;

  if (kind == 'disk_picker') {
    return c._state.decisions['flash.disk'];
  }
  if (kind == 'choose_one' && optionsFrom == 'os.fresh_install_options') {
    return c._state.decisions['flash.os'];
  }
  return null;
}

Future<String> _userFacingDiskNameForIdImpl(
  WizardController c,
  String diskId,
) async {
  try {
    final disks = await c.flash.listDisks();
    for (final disk in disks) {
      if (disk.id == diskId) return _userFacingDiskNameImpl(disk);
    }
  } catch (_) {
    // Logs are best-effort display only. The raw disk id is still used
    // for all safety checks and helper calls below.
  }
  return diskId;
}

String _userFacingDiskNameImpl(DiskInfo disk) {
  final model = disk.model.trim();
  if (_isFriendlyDiskModelImpl(model, disk)) return model;
  final bus = disk.bus.trim().toUpperCase();
  if (disk.removable || bus == 'USB' || bus == 'SD' || bus == 'MMC') {
    return 'Generic STORAGE DEVICE';
  }
  if (bus.isNotEmpty && bus != 'UNKNOWN') return '$bus storage device';
  return 'Storage device';
}

bool _isFriendlyDiskModelImpl(String model, DiskInfo disk) {
  if (model.isEmpty) return false;
  final lower = model.toLowerCase();
  if (lower == 'unknown' || lower == 'unknown disk') return false;
  if (_sameTechnicalDiskValueImpl(model, disk.id) ||
      _sameTechnicalDiskValueImpl(model, disk.path)) {
    return false;
  }
  return _physicalDriveNumberImpl(model) == null;
}

bool _sameTechnicalDiskValueImpl(String left, String right) {
  if (right.trim().isEmpty) return false;
  return left.trim().toLowerCase() == right.trim().toLowerCase();
}

String? _physicalDriveNumberImpl(String value) {
  final compact = value
      .trim()
      .replaceFirst(RegExp(r'^\\\\\.\\', caseSensitive: false), '')
      .replaceAll(RegExp(r'[\s_-]+'), '')
      .toLowerCase();
  final match = RegExp(r'^physicaldrive([0-9]+)$').firstMatch(compact);
  return match?.group(1);
}

Future<void> _runWaitForSshImpl(
  WizardController c,
  Map<String, dynamic> step,
) async {
  final firstBootAcknowledged =
      c._state.decisions[firstBootReadyForSshWaitDecision] == true;
  if (c._state.flow == WizardFlow.freshFlash && !firstBootAcknowledged) {
    c._log(
      step,
      '[handoff] reinstall the eMMC, power on the printer, then connect to it',
    );
    c.setCurrentStep('first-boot');
    throw const WizardHandoffRequiredException(
      step: 'first-boot',
      route: '/first-boot',
      message:
          'Install the eMMC in the printer, power it on, then connect to the printer to continue.',
    );
  }

  final host = c._state.sshHost;
  if (host == null || host.trim().isEmpty) {
    c._log(
      step,
      '[handoff] reinstall the eMMC, power on the printer, then connect to it',
    );
    c.setCurrentStep('first-boot');
    throw const WizardHandoffRequiredException(
      step: 'first-boot',
      route: '/first-boot',
      message:
          'Install the eMMC in the printer, power it on, then connect to the printer to continue.',
    );
  }
  final timeoutSecs = _positiveIntValue(step['timeout_seconds'], 600);
  final ok = await c.discovery.waitForSsh(
    host: host,
    timeout: Duration(seconds: timeoutSecs),
  );
  if (!ok) {
    throw StepExecutionException(
      'ssh did not come up within $timeoutSecs seconds',
    );
  }
  c._log(step, '[ssh] up at $host');
}

Future<void> _runVerifyImpl(
  WizardController c,
  Map<String, dynamic> step,
) async {
  final s = c._requireSession();
  for (final v in c._profile!.verifiers) {
    final kind = _stringValue(v.raw['kind']) ?? '';
    final optional = _boolValue(v.raw['optional']);
    switch (kind) {
      case 'ssh_command':
        final cmd = _stringValue(v.raw['command']);
        if (cmd == null || cmd.trim().isEmpty) {
          throw StepExecutionException(
            'verifier ${v.id} command must be a string',
          );
        }
        // Verifiers are supposed to be read-only checks. If a
        // profile author writes `sudo foo` inside a verify step,
        // that is either a mistake or a privilege-escalation
        // sneaking in through the back door - neither is what we
        // want. Run via ssh.run directly (no sudo-injection strip)
        // so any `sudo` inside the command prompts for a password
        // and fails fast, rather than silently picking up the
        // cached session password.
        final res = await c.ssh.run(s, cmd);
        final contains = _optionalVerifierString(v, 'expect_stdout_contains');
        final equals = _optionalVerifierString(v, 'expect_stdout_equals');
        var passed = res.success;
        if (contains != null) {
          passed = passed && res.stdout.contains(contains);
        }
        if (equals != null) {
          passed = passed && res.stdout.trim() == equals.trim();
        }
        c._log(step, '[verify] ${v.id}: ${passed ? "PASS" : "FAIL"}');
        if (!passed && !optional) {
          throw StepExecutionException('verifier ${v.id} failed');
        }
      case 'http_get':
        final host = c._state.sshHost;
        if (host == null) {
          c._log(step, '[verify] ${v.id}: no host - skipping');
          continue;
        }
        final url = (_stringValue(v.raw['url']) ?? '').replaceAll(
          '{{host}}',
          host,
        );
        try {
          final info = await c.moonraker.info(host: host);
          c._log(
            step,
            '[verify] ${v.id}: $url ${'->'} klippy_state=${info.klippyState}',
          );
        } catch (e) {
          c._log(step, '[verify] ${v.id}: $e');
          if (!optional) {
            throw StepExecutionException('verifier ${v.id} failed: $e');
          }
        }
      case 'moonraker_gcode':
        c._log(step, '[verify] ${v.id}: moonraker_gcode not yet wired');
      default:
        c._log(step, '[verify] ${v.id}: unknown kind $kind');
    }
  }
}

String? _optionalVerifierString(VerifierConfig verifier, String key) {
  final value = verifier.raw[key];
  if (value == null) return null;
  if (value is String) return value;
  throw StepExecutionException('verifier ${verifier.id} $key must be a string');
}

Future<void> _runConditionalImpl(
  WizardController c,
  Map<String, dynamic> step,
) async {
  final when = _stringValue(step['when']);
  if (when == null) return;
  final env = c._buildDslEnv();
  final matches = c._dsl.evaluate(when, env);
  if (!matches) {
    c._log(step, '[conditional] skipping - condition false');
    return;
  }
  final thenSteps = _stringKeyMapList(step['then']);
  for (final sub in thenSteps) {
    // Honor user-cancellation between sub-steps. Without this, a
    // conditional block of N slow steps swallows a cancel until the
    // entire block completes.
    if (c._cancelled) {
      throw WizardCancelledException(c._cancelReason ?? 'cancelled');
    }
    await c._runStep(sub);
  }
}

Map<String, Object?> _objectMap(Object? value) {
  if (value is! Map) return const {};
  final out = <String, Object?>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is String) out[key] = entry.value as Object?;
  }
  return out;
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

List<Map<String, dynamic>> _stringKeyMapList(Object? value) {
  if (value is! Iterable) return const [];
  return value.map(_stringKeyMap).whereType<Map<String, dynamic>>().toList();
}

List<String> _stringList(Object? value) {
  if (value is! Iterable) return const [];
  return value.whereType<String>().where((s) => s.isNotEmpty).toList();
}

String? _stringValue(Object? value) => value is String ? value : null;

bool _boolValue(Object? value) => value is bool ? value : false;

bool _boolValueOr(Object? value, bool fallback) =>
    value is bool ? value : fallback;

int _positiveIntValue(Object? value, int fallback) {
  final parsed = switch (value) {
    num() => value.toInt(),
    String() => int.tryParse(value.trim()),
    _ => null,
  };
  if (parsed == null || parsed <= 0) return fallback;
  return parsed;
}
