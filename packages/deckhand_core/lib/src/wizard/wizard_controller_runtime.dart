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
    return (declared['inputs'] as Map).cast<String, Object?>();
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
    final id = step['id'] as String? ?? 'unnamed';
    final kind = step['kind'] as String? ?? '';
    c._currentStepKind = kind;
    c._emit(StepStarted(id));
    final hash = canonicalInputHash(c._canonicalStepInputs(step));
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
  final commands = ((step['commands'] as List?) ?? const []).cast<String>();
  final ignore = step['ignore_errors'] as bool? ?? false;
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
  final pathIds = ((step['paths'] as List?) ?? const []).cast<String>();
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
        stepId: step['id'] as String? ?? 'snapshot_archive',
        message:
            'archive service not wired; skipping snapshot capture '
            '(install will proceed but config backup is your problem)',
      ),
    );
    return;
  }
  final pf = c._profile;
  if (pf == null) throw StateError('no profile loaded');
  final selectedRaw = c._state.decisions['snapshot.paths'];
  final selectedIds = <String>[];
  if (selectedRaw is List) {
    for (final v in selectedRaw) {
      selectedIds.add(v.toString());
    }
  }
  if (selectedIds.isEmpty) {
    c._emit(
      StepWarning(
        stepId: step['id'] as String? ?? 'snapshot_archive',
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
          stepId: step['id'] as String? ?? 'snapshot_archive',
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
        stepId: step['id'] as String? ?? 'snapshot_archive',
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
  final filename = step['filename'] as String? ?? 'deckhand.json';
  final targetDir =
      step['target_dir'] as String? ??
      '/home/${c._session!.user}/printer_data/config';
  final extra = (step['extra'] as Map?)?.cast<String, dynamic>() ?? const {};

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
    'id': step['id'] as String? ?? 'install_marker',
    'kind': 'write_file',
    'target': target,
    'content': json,
    'mode': '0644',
    'backup': step['backup'] as bool? ?? true,
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
    c._log(step, '[input] using existing decision: $existing');
    c._emit(DecisionRecorded(path: id, value: existing));
    return;
  }
  await c._awaitUserInput(id, step);
}

/// Checks known decision keys that may already hold the answer for
/// this step. Keeps the controller in sync with the pre-wizard
/// screens (flash_target_screen, choose_os_screen) without hardcoding
/// their step ids in the profile.
Object? _lookupExistingDecisionImpl(
  WizardController c,
  Map<String, dynamic> step,
) {
  final kind = step['kind'] as String? ?? '';
  final optionsFrom = step['options_from'] as String?;
  final id = step['id'] as String? ?? '';

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

Future<void> _runWaitForSshImpl(
  WizardController c,
  Map<String, dynamic> step,
) async {
  final host = c._state.sshHost;
  if (host == null) throw StepExecutionException('no ssh host set');
  final timeoutSecs = (step['timeout_seconds'] as num?)?.toInt() ?? 600;
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
    final kind = v.raw['kind'] as String? ?? '';
    switch (kind) {
      case 'ssh_command':
        final cmd = v.raw['command'] as String;
        // Verifiers are supposed to be read-only checks. If a
        // profile author writes `sudo foo` inside a verify step,
        // that is either a mistake or a privilege-escalation
        // sneaking in through the back door - neither is what we
        // want. Run via ssh.run directly (no sudo-injection strip)
        // so any `sudo` inside the command prompts for a password
        // and fails fast, rather than silently picking up the
        // cached session password.
        final res = await c.ssh.run(s, cmd);
        final contains = v.raw['expect_stdout_contains'] as String?;
        final equals = v.raw['expect_stdout_equals'] as String?;
        var passed = res.success;
        if (contains != null) {
          passed = passed && res.stdout.contains(contains);
        }
        if (equals != null) {
          passed = passed && res.stdout.trim() == equals.trim();
        }
        c._log(step, '[verify] ${v.id}: ${passed ? "PASS" : "FAIL"}');
        if (!passed && !(v.raw['optional'] as bool? ?? false)) {
          throw StepExecutionException('verifier ${v.id} failed');
        }
      case 'http_get':
        final host = c._state.sshHost;
        if (host == null) {
          c._log(step, '[verify] ${v.id}: no host - skipping');
          continue;
        }
        final url = (v.raw['url'] as String? ?? '').replaceAll(
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
          if (!(v.raw['optional'] as bool? ?? false)) {
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

Future<void> _runConditionalImpl(
  WizardController c,
  Map<String, dynamic> step,
) async {
  final when = step['when'] as String?;
  if (when == null) return;
  final env = c._buildDslEnv();
  final matches = c._dsl.evaluate(when, env);
  if (!matches) {
    c._log(step, '[conditional] skipping - condition false');
    return;
  }
  final thenSteps = ((step['then'] as List?) ?? const [])
      .whereType<Map>()
      .toList();
  for (final sub in thenSteps) {
    // Honor user-cancellation between sub-steps. Without this, a
    // conditional block of N slow steps swallows a cancel until the
    // entire block completes.
    if (c._cancelled) {
      throw WizardCancelledException(c._cancelReason ?? 'cancelled');
    }
    await c._runStep(sub.cast<String, dynamic>());
  }
}
