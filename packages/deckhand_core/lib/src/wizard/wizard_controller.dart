import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/printer_profile.dart';
import '../services/discovery_service.dart';
import '../services/elevated_helper_service.dart';
import '../services/flash_service.dart';
import '../services/moonraker_service.dart';
import '../services/profile_service.dart';
import '../services/security_service.dart';
import '../services/ssh_service.dart';
import '../services/upstream_service.dart';
import 'dsl.dart';
import 'printer_state_probe.dart';

/// Which high-level flow the wizard is running.
enum WizardFlow { none, stockKeep, freshFlash }

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
  });

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

  late final DslEvaluator _dsl = DslEvaluator(defaultPredicates());
  final _eventsController = StreamController<WizardEvent>.broadcast();
  final _pendingInput = <String, Completer<Object?>>{};

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

  Future<void> loadProfile(String profileId, {String? ref}) async {
    final cache = await profiles.ensureCached(profileId: profileId, ref: ref);
    final profile = await profiles.load(cache);
    _profile = profile;
    _profileCache = cache;
    _state = _state.copyWith(profileId: profileId);
    _emit(ProfileLoaded(profile));
  }

  Future<void> connectSsh({required String host, int? port}) async {
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
    _emit(SshConnected(host: host, user: session.user));
    // Fire the inventory probe in the background so the services /
    // files / screens screens render with machine-specific state
    // without making the user wait at the Connect step for it.
    unawaited(_refreshPrinterState());
  }

  /// Connect with a specific username/password. Used as the fallback when
  /// the profile's default credentials don't authenticate (e.g. the user
  /// has changed the stock password).
  Future<void> connectSshWithPassword({
    required String host,
    int? port,
    required String user,
    required String password,
  }) async {
    final pf = _profile;
    final p = port ?? pf?.ssh.defaultPort ?? 22;
    final session = await ssh.connect(
      host: host,
      port: p,
      credential: PasswordCredential(user: user, password: password),
    );
    _session = session;
    _sshPassword = password;
    _state = _state.copyWith(sshHost: host);
    _emit(SshConnected(host: host, user: session.user));
    unawaited(_refreshPrinterState());
  }

  /// Re-run the state probe against the current SSH session. Emits
  /// [PrinterStateRefreshed] when fresh data lands so screens can
  /// rebuild. Called automatically on connect; screens can call it
  /// manually (via [refreshPrinterState]) after a user action that
  /// changes the printer state (e.g. after the install flow
  /// completes and you navigate back to adjust decisions).
  Future<void> _refreshPrinterState() async {
    final s = _session;
    final pf = _profile;
    if (s == null || pf == null) return;
    try {
      final probe = PrinterStateProbe(ssh: ssh);
      final report = await probe.probe(session: s, profile: pf);
      _printerState = report;
      _emit(PrinterStateRefreshed(report));
    } catch (e) {
      // Probe is best-effort. If it fails (network blip, missing
      // systemctl, etc.) screens simply render the full abstract
      // option list like they did before probing existed.
      _emit(
        StepWarning(
          stepId: 'printer_state_probe',
          message: 'Could not probe printer state: $e',
        ),
      );
    }
  }

  /// Public entry point for screens that want to trigger a re-probe.
  Future<void> refreshPrinterState() => _refreshPrinterState();

  Future<void> setDecision(String path, Object value) async {
    final updated = Map<String, Object>.from(_state.decisions);
    updated[path] = value;
    _state = _state.copyWith(decisions: updated);
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
    return DslEnv(
      decisions: decisions,
      profile: _profile?.raw ?? const {},
    );
  }

  void setFlow(WizardFlow flow) {
    _state = _state.copyWith(flow: flow);
    _emit(FlowChanged(flow));
  }

  /// Resolve an outstanding user-input request. UI code calls this when
  /// the user has made a decision for a UI-driven step.
  void resolveUserInput(String stepId, Object? value) {
    final completer = _pendingInput.remove(stepId);
    completer?.complete(value);
  }

  Future<void> startExecution() async {
    final pf = _profile;
    if (pf == null) throw StateError('No profile loaded.');
    final flow = _state.flow == WizardFlow.stockKeep
        ? pf.flows.stockKeep
        : pf.flows.freshFlash;
    if (flow == null || !flow.enabled) {
      throw StateError('Flow ${_state.flow} is not enabled for this profile.');
    }

    for (final step in flow.steps) {
      final id = step['id'] as String? ?? 'unnamed';
      final kind = step['kind'] as String? ?? '';
      _currentStepKind = kind;
      _emit(StepStarted(id));
      try {
        await _runStep(step);
        _emit(StepCompleted(id));
      } catch (e) {
        _emit(StepFailed(stepId: id, error: '$e'));
        rethrow;
      } finally {
        _currentStepKind = null;
      }
    }
    _emit(const ExecutionCompleted());
  }

  Future<void> _runStep(Map<String, dynamic> step) async {
    final kind = step['kind'] as String? ?? '';
    final id = step['id'] as String? ?? '';
    switch (kind) {
      case 'ssh_commands':
        await _runSshCommands(step);
      case 'snapshot_paths':
        await _runSnapshotPaths(step);
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

  Future<void> _runSshCommands(Map<String, dynamic> step) async {
    _requireSession();
    final commands = ((step['commands'] as List?) ?? const []).cast<String>();
    final ignore = step['ignore_errors'] as bool? ?? false;
    for (final cmd in commands) {
      final rendered = _render(cmd);
      final res = await _runSsh(rendered);
      _log(step, '[ssh] $rendered -> exit ${res.exitCode}');
      if (!res.success && !ignore) {
        throw StepExecutionException(
          'Command failed: $rendered',
          stderr: res.stderr,
        );
      }
    }
  }

  Future<void> _runSnapshotPaths(Map<String, dynamic> step) async {
    _requireSession();
    final pathIds = ((step['paths'] as List?) ?? const []).cast<String>();
    final ts = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    for (final id in pathIds) {
      final path = _profile!.stockOs.paths.firstWhere(
        (x) => x.id == id,
        orElse: () => throw StepExecutionException('path "$id" not in profile'),
      );
      final snapshotTo = (path.snapshotTo ?? '${path.path}.stock.{{timestamp}}')
          .replaceAll('{{timestamp}}', ts);
      final rendered = _render(snapshotTo);
      final cmd =
          'if [ -e "${path.path}" ]; then mv "${path.path}" "$rendered"; fi';
      final res = await _runSsh(cmd);
      _log(step, '[snapshot] ${path.path} -> $rendered (exit ${res.exitCode})');
      if (!res.success) {
        throw StepExecutionException(
          'snapshot failed for ${path.path}',
          stderr: res.stderr,
        );
      }
    }
  }

  Future<void> _runInstallFirmware(Map<String, dynamic> step) async {
    _requireSession();
    final fw = _selectedFirmware();
    if (fw == null) throw StepExecutionException('no firmware selected');
    final install = fw.installPath ?? '~/klipper';
    _log(step, '[firmware] cloning ${fw.repo} @ ${fw.ref} -> $install');
    final cloneCmd =
        'if [ -d "$install/.git" ]; then cd "$install" && git fetch origin && git checkout ${fw.ref} && git pull --ff-only; '
        'else rm -rf "$install" && git clone --depth 1 -b ${fw.ref} ${fw.repo} "$install"; fi';
    final cloneRes = await _runSsh(
      cloneCmd,
      timeout: const Duration(minutes: 10),
    );
    if (!cloneRes.success) {
      throw StepExecutionException('clone failed', stderr: cloneRes.stderr);
    }

    final venv = fw.venvPath ?? '~/klippy-env';
    final venvCmd =
        'PY=\$(command -v python3.11 || command -v python3) && \$PY -m venv $venv && '
        '$venv/bin/pip install --quiet -U pip setuptools wheel && '
        '$venv/bin/pip install --quiet -r $install/scripts/klippy-requirements.txt';
    final venvRes = await _runSsh(
      venvCmd,
      timeout: const Duration(minutes: 15),
    );
    if (!venvRes.success) {
      throw StepExecutionException('venv setup failed', stderr: venvRes.stderr);
    }
    _log(step, '[firmware] venv ready at $venv');
  }

  Future<void> _runLinkExtras(Map<String, dynamic> step) async {
    final s = _requireSession();
    final fw = _selectedFirmware();
    if (fw == null) throw StepExecutionException('no firmware selected');
    final install = fw.installPath ?? '~/klipper';
    final sources = ((step['sources'] as List?) ?? const []).cast<String>();
    for (final src in sources) {
      final localPath = _resolveProfilePath(src);
      final basename = p.basename(localPath);
      final remote = '$install/klippy/extras/$basename';
      if (await Directory(localPath).exists()) {
        await _uploadDir(localPath, remote);
      } else {
        await ssh.upload(s, localPath, remote);
      }
      _log(step, '[link_extras] installed $basename');
    }
  }

  Future<void> _runInstallStack(Map<String, dynamic> step) async {
    _requireSession();
    final components = ((step['components'] as List?) ?? const [])
        .cast<String>();
    final stack = _profile!.stack;
    for (final c in components) {
      final name = c.replaceAll('?', '');
      final optional = c.endsWith('?');
      final cfg = _stackComponent(stack, name);
      if (cfg == null) {
        if (optional) continue;
        throw StepExecutionException('unknown stack component $name');
      }
      if (name == 'kiauh' && _state.decisions['kiauh'] == false) {
        _log(step, '[stack] kiauh skipped by user');
        continue;
      }
      final repo = cfg['repo'] as String?;
      final ref = cfg['ref'] as String? ?? 'master';
      final install = cfg['install_path'] as String?;
      if (repo != null && install != null) {
        final cmd =
            'if [ -d "$install/.git" ]; then cd "$install" && git pull --ff-only; '
            'else git clone --depth 1 -b $ref $repo "$install"; fi';
        final res = await _runSsh(cmd, timeout: const Duration(minutes: 10));
        if (!res.success) {
          throw StepExecutionException(
            '$name clone failed',
            stderr: res.stderr,
          );
        }
      }
      _log(step, '[stack] $name installed');
    }
  }

  Future<void> _runApplyServices(Map<String, dynamic> step) async {
    _requireSession();
    for (final svc in _profile!.stockOs.services) {
      final action =
          _state.decisions['service.${svc.id}'] as String? ?? svc.defaultAction;
      final unit = svc.raw['systemd_unit'] as String?;
      final proc = svc.raw['process_pattern'] as String?;
      switch (action) {
        case 'remove':
        case 'disable':
          if (unit != null) {
            await _runSsh(
              'sudo systemctl disable --now $unit 2>/dev/null || true',
            );
          }
          if (proc != null) {
            await _runSsh('sudo pkill -f "$proc" 2>/dev/null || true');
          }
          _log(step, '[services] ${svc.id}: disabled');
        case 'stub':
          _log(step, '[services] ${svc.id}: left as stub');
        default:
          _log(step, '[services] ${svc.id}: keeping');
      }
    }
  }

  Future<void> _runApplyFiles(Map<String, dynamic> step) async {
    _requireSession();
    for (final f in _profile!.stockOs.files) {
      final decision =
          _state.decisions['file.${f.id}'] as String? ?? f.defaultAction;
      if (decision != 'delete') continue;
      for (final path in f.paths) {
        if (_isDangerousPath(path)) {
          _log(step, '[files] SKIPPING dangerous path: $path');
          continue;
        }
        final String cmd;
        if (_hasGlob(path)) {
          // Glob path: `find <dir> -maxdepth 1 -name <pattern> -delete`
          // handles the expansion itself (so the shell doesn't need to)
          // and cleanly no-ops when the pattern matches nothing. Only
          // the trailing segment is allowed to contain wildcards; the
          // parent directory must be a concrete path so we refuse to
          // recurse into anything unexpected.
          final dir = p.posix.dirname(path);
          final pattern = p.posix.basename(path);
          if (_hasGlob(dir) || _isDangerousPath(dir)) {
            _log(step, '[files] SKIPPING unsafe glob directory: $dir');
            continue;
          }
          cmd =
              'sudo find ${_shellQuote(dir)} -maxdepth 1 -name ${_shellQuote(pattern)} -print -exec rm -rf {} +';
        } else {
          cmd = 'sudo rm -rf ${_shellQuote(path)}';
        }
        final res = await _runSsh(cmd);
        _log(step, '[files] rm ${f.id}: $path (exit ${res.exitCode})');
        if (res.stdout.trim().isNotEmpty) {
          for (final line in res.stdout.trim().split('\n')) {
            _log(step, '[files]   removed: $line');
          }
        }
      }
    }
  }

  bool _hasGlob(String path) => RegExp(r'[*?\[]').hasMatch(path);

  Future<void> _runWriteFile(Map<String, dynamic> step) async {
    final s = _requireSession();
    final target = step['target'] as String?;
    final templatePath = step['template'] as String?;
    final content = step['content'] as String?;
    if (target == null) {
      throw StepExecutionException('write_file missing target');
    }
    String rendered;
    if (content != null) {
      rendered = _render(content);
    } else if (templatePath != null) {
      final src = _resolveProfilePath(templatePath);
      rendered = _render(await File(src).readAsString());
    } else {
      throw StepExecutionException('write_file requires template or content');
    }

    // Explicit `sudo: true` wins; otherwise default to sudo for paths
    // outside the SSH user's home directory. We can't SFTP directly to
    // root-owned paths like /etc/apt/sources.list, so stage in /tmp
    // and mv into place.
    final useSudo = step['sudo'] as bool? ?? _looksLikeSystemPath(s, target);
    final mode = _parseFileMode(step['mode']);
    final owner = step['owner'] as String?;
    // Auto-snapshot the existing file before overwriting, unless the
    // step explicitly opts out (backup: false). System files (/etc/*)
    // are the priority case: rewriting sources.list or a systemd unit
    // silently is a recipe for unrecoverable mistakes when the profile
    // got it wrong. A `.deckhand-pre-<ts>` sibling is easy to restore.
    final backup = step['backup'] as bool? ?? true;

    final ts = DateTime.now().millisecondsSinceEpoch;
    final tmpLocal = p.join(Directory.systemTemp.path, 'deckhand-$ts.tmp');
    final remoteTmp = '/tmp/deckhand-write-$ts.tmp';
    await File(tmpLocal).writeAsString(rendered);

    try {
      if (backup) {
        final qTarget0 = _shellQuote(target);
        final backupPath = '$target.deckhand-pre-$ts';
        final qBackup = _shellQuote(backupPath);
        // Only snapshot if the target already exists. `cp -p` preserves
        // mode/owner/timestamps so a user-led rollback is byte-exact.
        final snapCmd = useSudo
            ? 'if [ -e $qTarget0 ]; then sudo cp -p $qTarget0 $qBackup; fi'
            : 'if [ -e $qTarget0 ]; then cp -p $qTarget0 $qBackup; fi';
        final snapRes = await _runSsh(snapCmd);
        if (!snapRes.success) {
          // Non-fatal: surface a warning but keep going - the user
          // explicitly triggered the write and might not care about
          // a backup failure on a fresh install (no prior file).
          _emit(
            StepWarning(
              stepId: step['id'] as String? ?? 'write_file',
              message: 'Could not snapshot existing $target before '
                  'overwrite: ${snapRes.stderr.trim()}',
            ),
          );
        } else if (snapRes.stdout.trim().isNotEmpty ||
            snapRes.stderr.trim().isEmpty) {
          _log(step, '[write_file] backup -> $backupPath');
        }
      }
      await ssh.upload(s, tmpLocal, remoteTmp);
      final qTmp = _shellQuote(remoteTmp);
      final qTarget = _shellQuote(target);
      final modeArg = mode != null ? '-m ${mode.toRadixString(8)} ' : '';
      final ownerArg = owner != null ? '-o ${_shellQuote(owner)} ' : '';
      final String cmd;
      if (useSudo) {
        // `install` atomically places the file with the right mode (and
        // optional owner). `rm -f` cleans up even if install is a no-op
        // symlink, though it usually consumes the source.
        cmd =
            'sudo install ${modeArg}${ownerArg}$qTmp $qTarget && rm -f $qTmp';
      } else {
        final chmod = mode != null
            ? ' && chmod ${mode.toRadixString(8)} $qTarget'
            : '';
        cmd = 'mv $qTmp $qTarget$chmod';
      }
      final res = await _runSsh(cmd);
      _log(
        step,
        '[write_file] wrote $target (${rendered.length} bytes'
        '${useSudo ? ', via sudo' : ''})',
      );
      if (!res.success) {
        // Make sure we don't leave the staged file behind.
        await _runSsh('rm -f $qTmp');
        throw StepExecutionException(
          'write_file $target failed',
          stderr: res.stderr,
        );
      }
    } finally {
      try {
        await File(tmpLocal).delete();
      } catch (_) {}
    }
  }

  bool _looksLikeSystemPath(SshSession s, String target) {
    // Anything under the login user's home (and /tmp) is writable
    // without elevation; everything else we assume needs sudo.
    if (target.startsWith('/home/${s.user}/')) return false;
    if (target.startsWith('/tmp/')) return false;
    return true;
  }

  /// Accepts an int (already decimal) or a string like `"0644"` / `"755"`
  /// / `"0o755"` and returns the integer mode. Returns null when the
  /// step omits `mode:`.
  int? _parseFileMode(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) {
      var raw = v.trim();
      if (raw.startsWith('0o') || raw.startsWith('0O')) {
        raw = raw.substring(2);
      }
      return int.parse(raw, radix: 8);
    }
    return null;
  }

  Future<void> _runInstallScreen(Map<String, dynamic> step) async {
    final s = _requireSession();
    final screenId = _state.decisions['screen'] as String?;
    if (screenId == null) {
      _log(step, '[screen] no screen selected - skipping install');
      return;
    }
    final screen = _profile!.screens.firstWhere(
      (sc) => sc.id == screenId,
      orElse: () => throw StepExecutionException('unknown screen $screenId'),
    );
    final sourceKind = screen.raw['source_kind'] as String?;
    if (sourceKind == 'bundled') {
      final src = _resolveProfilePath(screen.raw['source_path'] as String);
      final remote = '~/${p.basename(src)}';
      await _uploadDir(src, remote);
      final installScript = screen.raw['install_script'] as String?;
      if (installScript != null) {
        final srcInstall = _resolveProfilePath(installScript);
        const remoteInstall = '~/deckhand-screen-install.sh';
        await ssh.upload(s, srcInstall, remoteInstall, mode: 493); // 0o755
        final res = await _runSsh(
          'bash $remoteInstall',
          timeout: const Duration(minutes: 5),
        );
        if (!res.success) {
          throw StepExecutionException(
            'screen install script failed',
            stderr: res.stderr,
          );
        }
      }
      _log(step, '[screen] installed $screenId');
    } else if (sourceKind == 'restore_from_backup') {
      _log(
        step,
        '[screen] $screenId restore-from-backup requires a mounted backup image - not yet automated',
      );
    } else {
      _log(
        step,
        '[screen] $screenId source kind "$sourceKind" not implemented',
      );
    }
  }

  Future<void> _runFlashMcus(Map<String, dynamic> step) async {
    _requireSession();
    final which = ((step['which'] as List?) ?? const []).cast<String>();
    final fw = _selectedFirmware();
    if (fw == null) throw StepExecutionException('no firmware selected');
    final install = fw.installPath ?? '~/klipper';
    for (final id in which) {
      final mcu = _profile!.mcus.firstWhere(
        (m) => m.id == id,
        orElse: () => throw StepExecutionException('unknown mcu $id'),
      );
      final raw = mcu.raw;
      final configLines = _mcuConfig(raw);
      final writeConf =
          'cd $install && cat > .config <<"MCUCONF"\n$configLines\nMCUCONF\n'
          'make olddefconfig >/dev/null && make clean >/dev/null && make -j1';
      final build = await _runSsh(
        writeConf,
        timeout: const Duration(minutes: 20),
      );
      if (!build.success) {
        throw StepExecutionException(
          'mcu $id build failed',
          stderr: build.stderr,
        );
      }
      _log(step, '[mcu] built $id');

      final transport =
          (raw['transport'] as Map?)?.cast<String, dynamic>() ?? {};
      if (transport['requires_physical_access'] == true) {
        await _awaitUserInput('${mcu.id}_physical_prompt', {
          'id': '${mcu.id}_physical_prompt',
          'kind': 'prompt',
          'message':
              transport['physical_access_notes'] as String? ??
              'Put the MCU into bootloader mode.',
        });
      }
      _log(
        step,
        '[mcu] $id flash pending - refer to profile firmware/flash-$id.sh',
      );
    }
  }

  Future<void> _runOsDownload(Map<String, dynamic> step) async {
    final osId = _state.decisions['flash.os'] as String?;
    if (osId == null) throw StepExecutionException('no OS image selected');
    final opt = _profile!.os.freshInstallOptions.firstWhere(
      (o) => o.id == osId,
      orElse: () => throw StepExecutionException('unknown OS option $osId'),
    );
    final dest =
        step['dest'] as String? ??
        p.join(Directory.systemTemp.path, 'deckhand-${opt.id}.img');
    _log(step, '[os] downloading ${opt.url} -> $dest');

    final stepId = step['id'] as String? ?? 'os_download';
    String? sha;
    await for (final ev in upstream.osDownload(
      url: opt.url,
      destPath: dest,
      expectedSha256: opt.sha256,
    )) {
      if (ev.phase == OsDownloadPhase.done) {
        sha = ev.sha256;
        _emit(
          StepProgress(
            stepId: stepId,
            percent: 1.0,
            message: 'download complete',
          ),
        );
      } else if (ev.phase == OsDownloadPhase.failed) {
        throw StepExecutionException('os download failed');
      } else {
        _emit(
          StepProgress(
            stepId: stepId,
            percent: ev.fraction,
            message:
                '${(ev.bytesDone / (1 << 20)).toStringAsFixed(1)} MiB'
                '${ev.bytesTotal > 0 ? ' / ${(ev.bytesTotal / (1 << 20)).toStringAsFixed(1)} MiB' : ''}',
          ),
        );
      }
    }

    // Record artefact location + hash for the flash_disk step.
    await setDecision('flash.image_path', dest);
    if (sha != null) {
      await setDecision('flash.image_sha256', sha);
    }
    _log(step, '[os] ready at $dest${sha != null ? " (sha256 $sha)" : ""}');
  }

  Future<void> _runFlashDisk(Map<String, dynamic> step) async {
    final diskId = _state.decisions['flash.disk'] as String?;
    if (diskId == null) throw StepExecutionException('no flash disk selected');
    final imagePath = _state.decisions['flash.image_path'] as String?;
    if (imagePath == null) {
      throw StepExecutionException(
        'no image path recorded - did os_download run?',
      );
    }
    final helper = elevatedHelper;
    if (helper == null) {
      throw StepExecutionException(
        'elevated helper not configured - cannot write raw disk',
      );
    }
    final token = await security.issueConfirmationToken(
      operation: 'write_image',
      target: diskId,
    );
    final verify = step['verify_after_write'] as bool? ?? true;
    final expectedSha = _state.decisions['flash.image_sha256'] as String?;
    final stepId = step['id'] as String? ?? 'flash_disk';
    _log(step, '[flash] writing $imagePath -> $diskId (verify=$verify)');

    await for (final ev in helper.writeImage(
      imagePath: imagePath,
      diskId: diskId,
      confirmationToken: token.value,
      verifyAfterWrite: verify,
      expectedSha256: expectedSha,
    )) {
      final pct = ev.fraction;
      _emit(StepProgress(stepId: stepId, percent: pct, message: ev.message));
      if (ev.phase == FlashPhase.failed) {
        throw StepExecutionException(ev.message ?? 'flash failed');
      }
    }
    _log(step, '[flash] done');
  }

  Future<void> _runScript(Map<String, dynamic> step) async {
    final s = _requireSession();
    final rel = step['path'] as String?;
    if (rel == null) {
      throw StepExecutionException('script step missing "path"');
    }
    final local = _resolveProfilePath(rel);
    if (!await File(local).exists()) {
      throw StepExecutionException('script not found: $rel');
    }
    final remote = '/tmp/deckhand-${p.basename(rel)}';
    await ssh.upload(s, local, remote, mode: 493); // 0o755
    final interpreter = step['interpreter'] as String? ?? 'bash';
    final extraArgs = ((step['args'] as List?) ?? const []).cast<String>();
    final ignoreErrors = step['ignore_errors'] as bool? ?? false;
    final timeoutSecs = (step['timeout_seconds'] as num?)?.toInt() ?? 600;
    // Two orthogonal knobs, intentionally un-coupled:
    //   - `sudo: true`  -> wrap the whole invocation in `sudo -E`
    //                      so the script runs as root from line 1.
    //   - `askpass`     -> stand up an askpass helper + a PATH-shimmed
    //                      `sudo` wrapper so any *internal* `sudo X`
    //                      the script issues can authenticate without
    //                      a pty. On by default whenever we have a
    //                      cached password (i.e. password SSH). Turn
    //                      off with `askpass: false` for scripts you
    //                      want to prove don't elevate at all.
    final useSudo = step['sudo'] as bool? ?? false;
    final setUpAskpass =
        (step['askpass'] as bool? ?? true) && _sshPassword != null;

    final argStr = extraArgs.map(_shellQuote).join(' ');
    final baseCmd = argStr.isEmpty
        ? '$interpreter $remote'
        : '$interpreter $remote $argStr';

    String envPrefix = '';
    _ScriptSudoHelper? helper;
    if (setUpAskpass) {
      helper = await _installSudoAskpassHelper();
      envPrefix =
          'SUDO_ASKPASS=${_shellQuote(helper.askpassPath)} '
          'PATH=${_shellQuote(helper.binDir)}:\$PATH ';
    }
    // If askpass is staged, the outer sudo (if requested) routes
    // through the same helper via `-A`, so the whole command ships
    // with an env prefix and no `sudo ` at position 0 - _runSsh
    // leaves it alone. Without askpass, fall back to `sudo -E` and
    // let _runSsh strip it to forward the password via sudo -S.
    final String cmd;
    if (useSudo && setUpAskpass) {
      cmd = '${envPrefix}sudo -A -E $baseCmd';
    } else if (useSudo) {
      cmd = 'sudo -E $baseCmd';
    } else {
      cmd = '$envPrefix$baseCmd';
    }
    _log(
      step,
      '[script] running $rel'
      '${useSudo ? " (root)" : ""}'
      '${setUpAskpass ? " (askpass)" : ""}',
    );
    final res = await _runSsh(cmd, timeout: Duration(seconds: timeoutSecs));
    if (res.stdout.trim().isNotEmpty) {
      for (final line in res.stdout.trim().split('\n')) {
        _log(step, '[script]   $line');
      }
    }
    if (!res.success && !ignoreErrors) {
      // Sniff a sudoers-blocks-askpass configuration and give the
      // profile author a usable pointer instead of the raw sudo
      // error. Typical culprit: `Defaults !visiblepw` or a missing
      // `mks ALL=(ALL) NOPASSWD:` line combined with requiretty.
      if (_looksLikeSudoPtyError(res.stderr)) {
        throw StepExecutionException(
          'script $rel could not authenticate for sudo over an SSH '
          'session without a tty. Check the printer\'s sudoers config: '
          'either grant passwordless sudo for this user, or ensure '
          'SUDO_ASKPASS is permitted (no `Defaults requiretty`, no '
          '`Defaults !visiblepw`).',
          stderr: res.stderr,
        );
      }
      throw StepExecutionException(
        'script $rel failed (exit ${res.exitCode})',
        stderr: res.stderr,
      );
    }
    _log(step, '[script] done ($rel, exit ${res.exitCode})');
  }

  /// Stages a temporary sudo-askpass helper + `sudo` wrapper on the
  /// remote printer.
  ///
  /// - `<askpassPath>` is a 0700 shell script that prints the cached
  ///   SSH password on stdout. sudo reads it via `SUDO_ASKPASS` when
  ///   invoked with `-A`.
  /// - `<binDir>/sudo` is a 0755 shim that forwards to `/usr/bin/sudo
  ///   -A "$@"`. With `<binDir>` at the front of PATH, every `sudo`
  ///   call inside the script (including `sudo apt-get`, `sudo
  ///   systemctl`, etc.) transparently uses askpass.
  ///
  /// Both files live in `/tmp` and the caller is expected to remove
  /// them once the script completes (see the `finally` block in
  /// `_runScript`). Leaving them around briefly is acceptable: the
  /// printer is already authenticated via SSH with the same password,
  /// so there's no leak of a higher-privilege secret.
  Future<_ScriptSudoHelper> _installSudoAskpassHelper() async {
    // Reuse within a single WizardController lifetime: the helper
    // costs two uploads + a chmod, and the password in it is the same
    // for every step. Cleared in dispose().
    final cached = _sessionAskpass;
    if (cached != null) return cached;

    final s = _requireSession();
    final pw = _sshPassword;
    if (pw == null) {
      throw StateError('cannot install askpass helper without a password');
    }
    final ts = DateTime.now().microsecondsSinceEpoch;
    final askpassPath = '/tmp/deckhand-askpass-$ts';
    final binDir = '/tmp/deckhand-bin-$ts';

    // askpass: print the password. Single-quoted via _shellQuote so
    // special characters survive the trip through bash unmangled.
    final askpassBody = "#!/bin/sh\nprintf '%s' ${_shellQuote(pw)}\n";
    final askpassLocal = p.join(
      Directory.systemTemp.path,
      'deckhand-askpass-$ts.sh',
    );
    await File(askpassLocal).writeAsString(askpassBody);
    try {
      await ssh.upload(s, askpassLocal, askpassPath, mode: 448); // 0o700
    } finally {
      try {
        await File(askpassLocal).delete();
      } catch (_) {}
    }
    // Belt + suspenders: some SFTP servers ignore the `mode` hint we
    // passed at upload time. Force 0700 explicitly, and pre-empt any
    // umask weirdness while we're here.
    await ssh.run(s, 'chmod 700 ${_shellQuote(askpassPath)}');

    // Wrapper: call real sudo with -A so it uses askpass.
    const wrapperBody =
        '#!/bin/sh\nexec /usr/bin/sudo -A "\$@"\n';
    final wrapperLocal = p.join(
      Directory.systemTemp.path,
      'deckhand-sudo-$ts.sh',
    );
    await File(wrapperLocal).writeAsString(wrapperBody);
    try {
      await ssh.run(s, 'mkdir -p ${_shellQuote(binDir)}');
      await ssh.upload(s, wrapperLocal, '$binDir/sudo', mode: 493); // 0o755
    } finally {
      try {
        await File(wrapperLocal).delete();
      } catch (_) {}
    }
    await ssh.run(s, 'chmod 755 ${_shellQuote('$binDir/sudo')}');

    final helper = _ScriptSudoHelper(
      askpassPath: askpassPath,
      binDir: binDir,
    );
    _sessionAskpass = helper;
    return helper;
  }

  /// Heuristic: does this stderr output look like sudo failing to
  /// authenticate in no-pty mode? If so, we can surface a much better
  /// message than "script exited 1". Matches the common Debian/Ubuntu
  /// signatures; not locale-aware, but sudo defaults to English for
  /// these paths.
  bool _looksLikeSudoPtyError(String stderr) {
    final lower = stderr.toLowerCase();
    return lower.contains('a terminal is required') ||
        lower.contains('no tty present') ||
        lower.contains('askpass helper') ||
        lower.contains('a password is required');
  }

  /// Writes `~/printer_data/config/<filename>` (default `deckhand.json`)
  /// so the connect screen can recognise this printer as one Deckhand
  /// has already processed - even after the user strips out the stock
  /// vendor artefacts (`phrozen_dev`, MKS bloat, etc.) we were keying
  /// on before. Moonraker serves the file under the `config` root, so
  /// no Klipper restart or printer.cfg surgery is needed.
  Future<void> _runInstallMarker(Map<String, dynamic> step) async {
    _requireSession();
    final pf = _profile;
    if (pf == null) throw StepExecutionException('no profile loaded');
    final filename = step['filename'] as String? ?? 'deckhand.json';
    final targetDir =
        step['target_dir'] as String? ??
        '/home/${_session!.user}/printer_data/config';
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
    final mkdir = await ssh.run(_requireSession(), 'mkdir -p ${_shellQuote(targetDir)}');
    if (!mkdir.success) {
      throw StepExecutionException(
        'could not create $targetDir',
        stderr: mkdir.stderr,
      );
    }

    // Stage + mv (same pattern as _runWriteFile). Tempfile stays
    // under the user's control; no elevation needed for the Moonraker
    // config root.
    final ts = DateTime.now().millisecondsSinceEpoch;
    final tmpLocal = p.join(Directory.systemTemp.path, 'deckhand-marker-$ts.tmp');
    final remoteTmp = '/tmp/deckhand-marker-$ts.tmp';
    await File(tmpLocal).writeAsString(json);
    try {
      await ssh.upload(_requireSession(), tmpLocal, remoteTmp);
      final res = await _runSsh(
        'mv ${_shellQuote(remoteTmp)} ${_shellQuote(target)}',
      );
      if (!res.success) {
        await _runSsh('rm -f ${_shellQuote(remoteTmp)}');
        throw StepExecutionException(
          'could not write marker to $target',
          stderr: res.stderr,
        );
      }
      _log(step, '[marker] wrote $target (${json.length} bytes)');
    } finally {
      try {
        await File(tmpLocal).delete();
      } catch (_) {}
    }
  }

  /// For `choose_one` / `disk_picker` steps: if a pre-wizard screen
  /// already recorded the decision, emit the resolution and move on;
  /// otherwise fall back to awaiting user input.
  Future<void> _resolveOrAwaitInput(
    String id,
    Map<String, dynamic> step,
  ) async {
    final existing = _lookupExistingDecision(step);
    if (existing != null) {
      _log(step, '[input] using existing decision: $existing');
      _emit(DecisionRecorded(path: id, value: existing));
      return;
    }
    await _awaitUserInput(id, step);
  }

  /// Checks known decision keys that may already hold the answer for
  /// this step. Keeps the controller in sync with the pre-wizard
  /// screens (flash_target_screen, choose_os_screen) without hardcoding
  /// their step ids in the profile.
  Object? _lookupExistingDecision(Map<String, dynamic> step) {
    final kind = step['kind'] as String? ?? '';
    final optionsFrom = step['options_from'] as String?;
    final id = step['id'] as String? ?? '';

    // Most specific first: step id.
    final byId = _state.decisions[id];
    if (byId != null) return byId;

    if (kind == 'disk_picker') {
      return _state.decisions['flash.disk'];
    }
    if (kind == 'choose_one' && optionsFrom == 'os.fresh_install_options') {
      return _state.decisions['flash.os'];
    }
    return null;
  }

  Future<void> _runWaitForSsh(Map<String, dynamic> step) async {
    final host = _state.sshHost;
    if (host == null) throw StepExecutionException('no ssh host set');
    final timeoutSecs = (step['timeout_seconds'] as num?)?.toInt() ?? 600;
    final ok = await discovery.waitForSsh(
      host: host,
      timeout: Duration(seconds: timeoutSecs),
    );
    if (!ok)
      throw StepExecutionException(
        'ssh did not come up within $timeoutSecs seconds',
      );
    _log(step, '[ssh] up at $host');
  }

  Future<void> _runVerify(Map<String, dynamic> step) async {
    _requireSession();
    for (final v in _profile!.verifiers) {
      final kind = v.raw['kind'] as String? ?? '';
      switch (kind) {
        case 'ssh_command':
          final cmd = v.raw['command'] as String;
          final res = await _runSsh(cmd);
          final contains = v.raw['expect_stdout_contains'] as String?;
          final equals = v.raw['expect_stdout_equals'] as String?;
          var passed = res.success;
          if (contains != null)
            passed = passed && res.stdout.contains(contains);
          if (equals != null)
            passed = passed && res.stdout.trim() == equals.trim();
          _log(step, '[verify] ${v.id}: ${passed ? "PASS" : "FAIL"}');
          if (!passed && !(v.raw['optional'] as bool? ?? false)) {
            throw StepExecutionException('verifier ${v.id} failed');
          }
        case 'http_get':
          final host = _state.sshHost;
          if (host == null) {
            _log(step, '[verify] ${v.id}: no host - skipping');
            continue;
          }
          final url = (v.raw['url'] as String? ?? '').replaceAll(
            '{{host}}',
            host,
          );
          try {
            final info = await moonraker.info(host: host);
            _log(
              step,
              '[verify] ${v.id}: $url → klippy_state=${info.klippyState}',
            );
          } catch (e) {
            _log(step, '[verify] ${v.id}: $e');
            if (!(v.raw['optional'] as bool? ?? false)) {
              throw StepExecutionException('verifier ${v.id} failed: $e');
            }
          }
        case 'moonraker_gcode':
          _log(step, '[verify] ${v.id}: moonraker_gcode not yet wired');
        default:
          _log(step, '[verify] ${v.id}: unknown kind $kind');
      }
    }
  }

  Future<void> _runConditional(Map<String, dynamic> step) async {
    final when = step['when'] as String?;
    if (when == null) return;
    final env = _buildDslEnv();
    final matches = _dsl.evaluate(when, env);
    if (!matches) {
      _log(step, '[conditional] skipping - condition false');
      return;
    }
    final thenSteps = ((step['then'] as List?) ?? const [])
        .whereType<Map>()
        .toList();
    for (final sub in thenSteps) {
      await _runStep(sub.cast<String, dynamic>());
    }
  }

  Future<Object?> _awaitUserInput(String id, Map<String, dynamic> step) async {
    final completer = Completer<Object?>();
    _pendingInput[id] = completer;
    _emit(UserInputRequired(stepId: id, step: step));
    return completer.future;
  }

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
  Future<SshCommandResult> _runSsh(
    String command, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    final s = _requireSession();
    final stripped = _stripSudoPrefix(command);
    if (stripped != null && _sshPassword != null) {
      return ssh.run(
        s,
        stripped,
        timeout: timeout,
        sudoPassword: _sshPassword,
      );
    }
    return ssh.run(s, command, timeout: timeout);
  }

  /// Returns the command with the `sudo` token removed if [command]
  /// begins with sudo / /usr/bin/sudo / /bin/sudo. Returns null for
  /// everything else (subshells, env-prefixed commands, commands that
  /// start with any other word).
  ///
  /// Compound commands (`sudo X && rm Y`, `sudo X | grep Y`) are
  /// matched - the outer `sudo -S` replacement still produces the
  /// right behaviour because we only authenticate sudo and let the
  /// rest of the shell line run unchanged.
  String? _stripSudoPrefix(String command) {
    final m = RegExp(
      r'^(?<sudo>sudo|/usr/bin/sudo|/bin/sudo)(?:\s+(?<rest>.*))?$',
    ).firstMatch(command);
    if (m == null) return null;
    return m.namedGroup('rest') ?? '';
  }

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

  /// Turn a profile-declared relative path into an absolute local path.
  ///
  /// Three conventions, in priority order:
  ///   - absolute (`/etc/foo`): returned as-is.
  ///   - profile-local (`./scripts/foo.sh`): resolved against the
  ///     profile's directory (where profile.yaml lives).
  ///   - repo-root-relative (`shared/scripts/build-python.sh`): resolved
  ///     against the deckhand-builds repo root. Profile dirs live at
  ///     `<root>/printers/<id>/`, so the repo root is two levels up.
  ///
  /// Bare paths without a prefix default to profile-local (the legacy
  /// behaviour) - add `./` for new profiles to make the intent loud.
  String _resolveProfilePath(String ref) {
    final profileDir = _profileCache?.localPath ?? '.';
    if (ref.startsWith('/')) return ref;
    if (ref.startsWith('./')) return p.join(profileDir, ref.substring(2));
    // `shared/` is the repo-level tree of scripts and templates reused
    // across printers. Resolve it against the repo root.
    if (ref.startsWith('shared/') || ref.startsWith('shared\\')) {
      final repoRoot = p.dirname(p.dirname(profileDir));
      return p.join(repoRoot, ref);
    }
    return p.join(profileDir, ref);
  }

  Future<void> _uploadDir(String localDir, String remote) async {
    final s = _requireSession();
    final tmpTar = p.join(
      Directory.systemTemp.path,
      'deckhand-upload-${DateTime.now().millisecondsSinceEpoch}.tar',
    );
    final result = await Process.run('tar', [
      '-cf',
      tmpTar,
      '-C',
      p.dirname(localDir),
      p.basename(localDir),
    ]);
    if (result.exitCode != 0) {
      throw StepExecutionException('local tar failed: ${result.stderr}');
    }
    try {
      final remoteTar =
          '/tmp/deckhand-upload-${DateTime.now().millisecondsSinceEpoch}.tar';
      await ssh.upload(s, tmpTar, remoteTar);
      final extract =
          'mkdir -p "$remote" && tar -xf "$remoteTar" -C "\$(dirname "$remote")" && rm -f "$remoteTar"';
      final res = await _runSsh(extract);
      if (!res.success) {
        throw StepExecutionException(
          'remote extract failed',
          stderr: res.stderr,
        );
      }
    } finally {
      try {
        await File(tmpTar).delete();
      } catch (_) {}
    }
  }

  String _mcuConfig(Map<String, dynamic> mcu) {
    final chip = mcu['chip'] as String? ?? '';
    final clock = mcu['clock_hz'] as num? ?? 0;
    final clockRef = mcu['clock_ref_hz'] as num? ?? 0;
    final flashOffset = mcu['application_offset'] as String? ?? '';
    final transport = (mcu['transport'] as Map?)?.cast<String, dynamic>() ?? {};
    final selectKey = transport['select'] as String? ?? '';
    final baud = transport['baud'] as num?;
    final lines = [
      'CONFIG_MACH_STM32=y',
      'CONFIG_MCU="$chip"',
      'CONFIG_CLOCK_FREQ=$clock',
      'CONFIG_CLOCK_REF_FREQ=$clockRef',
      if (flashOffset.isNotEmpty)
        'CONFIG_FLASH_APPLICATION_ADDRESS=$flashOffset',
      'CONFIG_${selectKey.toUpperCase()}=y',
      if (baud != null) 'CONFIG_SERIAL_BAUD=$baud',
    ];
    return lines.join('\n');
  }

  bool _isDangerousPath(String path) {
    const dangerous = {
      '/',
      '/bin',
      '/boot',
      '/etc',
      '/home',
      '/lib',
      '/lib64',
      '/opt',
      '/root',
      '/run',
      '/sbin',
      '/srv',
      '/sys',
      '/usr',
      '/var',
    };
    return dangerous.contains(path);
  }

  String _shellQuote(String s) {
    final escaped = s.replaceAll("'", r"'\''");
    return "'$escaped'";
  }

  String _render(String template) {
    return template.replaceAllMapped(RegExp(r'\{\{([^}]+)\}\}'), (m) {
      final key = m.group(1)!.trim();
      if (key == 'timestamp') {
        return DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
      }
      if (key.startsWith('decisions.')) {
        return '${_state.decisions[key.substring('decisions.'.length)] ?? ''}';
      }
      if (key.startsWith('profile.')) {
        return '${_profile?.raw[key.substring('profile.'.length)] ?? ''}';
      }
      if (key.startsWith('firmware.')) {
        final fw = _selectedFirmware();
        if (fw == null) return '';
        switch (key) {
          case 'firmware.install_path':
            return fw.installPath ?? '';
          case 'firmware.venv_path':
            return fw.venvPath ?? '';
          case 'firmware.id':
            return fw.id;
          case 'firmware.ref':
            return fw.ref;
          case 'firmware.repo':
            return fw.repo;
        }
      }
      return m.group(0)!;
    });
  }

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

class WizardState {
  const WizardState({
    required this.profileId,
    required this.decisions,
    required this.currentStep,
    required this.flow,
    this.sshHost,
  });

  factory WizardState.initial() => const WizardState(
    profileId: '',
    decisions: {},
    currentStep: 'welcome',
    flow: WizardFlow.none,
  );

  final String profileId;
  final Map<String, Object> decisions;
  final String currentStep;
  final WizardFlow flow;
  final String? sshHost;

  WizardState copyWith({
    String? profileId,
    Map<String, Object>? decisions,
    String? currentStep,
    WizardFlow? flow,
    String? sshHost,
  }) => WizardState(
    profileId: profileId ?? this.profileId,
    decisions: decisions ?? this.decisions,
    currentStep: currentStep ?? this.currentStep,
    flow: flow ?? this.flow,
    sshHost: sshHost ?? this.sshHost,
  );
}

class StepExecutionException implements Exception {
  StepExecutionException(this.message, {this.stderr});
  final String message;
  final String? stderr;
  @override
  String toString() =>
      'StepExecutionException: $message${stderr != null && stderr!.isNotEmpty ? "\n$stderr" : ""}';
}

sealed class WizardEvent {
  const WizardEvent();
}

class ProfileLoaded extends WizardEvent {
  const ProfileLoaded(this.profile);
  final PrinterProfile profile;
}

class SshConnected extends WizardEvent {
  const SshConnected({required this.host, required this.user});
  final String host;
  final String user;
}

class DecisionRecorded extends WizardEvent {
  const DecisionRecorded({required this.path, required this.value});
  final String path;
  final Object value;
}

class FlowChanged extends WizardEvent {
  const FlowChanged(this.flow);
  final WizardFlow flow;
}

class StepStarted extends WizardEvent {
  const StepStarted(this.stepId);
  final String stepId;
}

class StepProgress extends WizardEvent {
  const StepProgress({
    required this.stepId,
    required this.percent,
    this.message,
  });
  final String stepId;
  final double percent;
  final String? message;
}

class StepLog extends WizardEvent {
  const StepLog({required this.stepId, required this.line});
  final String stepId;
  final String line;
}

class StepCompleted extends WizardEvent {
  const StepCompleted(this.stepId);
  final String stepId;
}

class StepFailed extends WizardEvent {
  const StepFailed({required this.stepId, required this.error});
  final String stepId;
  final String error;
}

class StepWarning extends WizardEvent {
  const StepWarning({required this.stepId, required this.message});
  final String stepId;
  final String message;
}

class UserInputRequired extends WizardEvent {
  const UserInputRequired({required this.stepId, required this.step});
  final String stepId;
  final Map<String, dynamic> step;
}

class ExecutionCompleted extends WizardEvent {
  const ExecutionCompleted();
}

/// Emitted once the state probe lands fresh data. Screens watching
/// `wizardStateProvider` rebuild on this (via the generic stream)
/// and re-render with machine-specific state applied.
class PrinterStateRefreshed extends WizardEvent {
  const PrinterStateRefreshed(this.state);
  final PrinterState state;
}
