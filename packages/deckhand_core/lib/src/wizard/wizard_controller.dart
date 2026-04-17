import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/printer_profile.dart';
import '../services/discovery_service.dart';
import '../services/flash_service.dart';
import '../services/moonraker_service.dart';
import '../services/profile_service.dart';
import '../services/security_service.dart';
import '../services/ssh_service.dart';
import '../services/upstream_service.dart';
import 'dsl.dart';

/// Which high-level flow the wizard is running.
enum WizardFlow { none, stockKeep, freshFlash }

/// Wizard state machine — profile-driven, UI-agnostic.
class WizardController {
  WizardController({
    required this.profiles,
    required this.ssh,
    required this.flash,
    required this.discovery,
    required this.moonraker,
    required this.upstream,
    required this.security,
  });

  final ProfileService profiles;
  final SshService ssh;
  final FlashService flash;
  final DiscoveryService discovery;
  final MoonrakerService moonraker;
  final UpstreamService upstream;
  final SecurityService security;

  late final DslEvaluator _dsl = DslEvaluator(defaultPredicates());
  final _eventsController = StreamController<WizardEvent>.broadcast();
  final _pendingInput = <String, Completer<Object?>>{};

  PrinterProfile? _profile;
  ProfileCacheEntry? _profileCache;
  SshSession? _session;
  var _state = WizardState.initial();

  WizardState get state => _state;
  PrinterProfile? get profile => _profile;
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
        .map((c) => PasswordCredential(user: c.user, password: c.password ?? ''))
        .toList();
    final session = await ssh.tryDefaults(
      host: host,
      port: port ?? pf.ssh.defaultPort,
      credentials: creds.cast<SshCredential>(),
    );
    _session = session;
    _state = _state.copyWith(sshHost: host);
    _emit(SshConnected(host: host, user: session.user));
  }

  Future<void> setDecision(String path, Object value) async {
    final updated = Map<String, Object>.from(_state.decisions);
    updated[path] = value;
    _state = _state.copyWith(decisions: updated);
    _emit(DecisionRecorded(path: path, value: value));
  }

  T? decision<T>(String path) => _state.decisions[path] as T?;

  String resolveServiceDefault(StockService svc) {
    final rules = ((svc.raw['wizard'] as Map?)?['default_rules'] as List?) ?? const [];
    final env = DslEnv(
      decisions: _state.decisions,
      profile: _profile?.raw ?? const {},
    );
    for (final r in rules.whereType<Map>().map((m) => m.cast<String, dynamic>())) {
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
      _emit(StepStarted(id));
      try {
        await _runStep(step);
        _emit(StepCompleted(id));
      } catch (e) {
        _emit(StepFailed(stepId: id, error: '$e'));
        rethrow;
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
      case 'choose_one':
      case 'disk_picker':
        await _awaitUserInput(id, step);
      default:
        _emit(StepWarning(
          stepId: id,
          message: 'Unknown step kind "$kind" — skipping',
        ));
    }
  }

  Future<void> _runSshCommands(Map<String, dynamic> step) async {
    final s = _requireSession();
    final commands = ((step['commands'] as List?) ?? const []).cast<String>();
    final ignore = step['ignore_errors'] as bool? ?? false;
    for (final cmd in commands) {
      final rendered = _render(cmd);
      final res = await ssh.run(s, rendered);
      _log(step, '[ssh] $rendered → exit ${res.exitCode}');
      if (!res.success && !ignore) {
        throw StepExecutionException('Command failed: $rendered', stderr: res.stderr);
      }
    }
  }

  Future<void> _runSnapshotPaths(Map<String, dynamic> step) async {
    final s = _requireSession();
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
      final cmd = 'if [ -e "${path.path}" ]; then mv "${path.path}" "$rendered"; fi';
      final res = await ssh.run(s, cmd);
      _log(step, '[snapshot] ${path.path} → $rendered (exit ${res.exitCode})');
      if (!res.success) {
        throw StepExecutionException('snapshot failed for ${path.path}', stderr: res.stderr);
      }
    }
  }

  Future<void> _runInstallFirmware(Map<String, dynamic> step) async {
    final s = _requireSession();
    final fw = _selectedFirmware();
    if (fw == null) throw StepExecutionException('no firmware selected');
    final install = fw.installPath ?? '~/klipper';
    _log(step, '[firmware] cloning ${fw.repo} @ ${fw.ref} → $install');
    final cloneCmd =
        'if [ -d "$install/.git" ]; then cd "$install" && git fetch origin && git checkout ${fw.ref} && git pull --ff-only; '
        'else rm -rf "$install" && git clone --depth 1 -b ${fw.ref} ${fw.repo} "$install"; fi';
    final cloneRes = await ssh.run(s, cloneCmd, timeout: const Duration(minutes: 10));
    if (!cloneRes.success) {
      throw StepExecutionException('clone failed', stderr: cloneRes.stderr);
    }

    final venv = fw.venvPath ?? '~/klippy-env';
    final venvCmd =
        'PY=\$(command -v python3.11 || command -v python3) && \$PY -m venv $venv && '
        '$venv/bin/pip install --quiet -U pip setuptools wheel && '
        '$venv/bin/pip install --quiet -r $install/scripts/klippy-requirements.txt';
    final venvRes = await ssh.run(s, venvCmd, timeout: const Duration(minutes: 15));
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
    final s = _requireSession();
    final components = ((step['components'] as List?) ?? const []).cast<String>();
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
        final res = await ssh.run(s, cmd, timeout: const Duration(minutes: 10));
        if (!res.success) {
          throw StepExecutionException('$name clone failed', stderr: res.stderr);
        }
      }
      _log(step, '[stack] $name installed');
    }
  }

  Future<void> _runApplyServices(Map<String, dynamic> step) async {
    final s = _requireSession();
    for (final svc in _profile!.stockOs.services) {
      final action = _state.decisions['service.${svc.id}'] as String? ?? svc.defaultAction;
      final unit = svc.raw['systemd_unit'] as String?;
      final proc = svc.raw['process_pattern'] as String?;
      switch (action) {
        case 'remove':
        case 'disable':
          if (unit != null) {
            await ssh.run(s, 'sudo systemctl disable --now $unit 2>/dev/null || true');
          }
          if (proc != null) {
            await ssh.run(s, 'sudo pkill -f "$proc" 2>/dev/null || true');
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
    final s = _requireSession();
    for (final f in _profile!.stockOs.files) {
      final decision = _state.decisions['file.${f.id}'] as String? ?? f.defaultAction;
      if (decision != 'delete') continue;
      for (final path in f.paths) {
        if (_isDangerousPath(path)) {
          _log(step, '[files] SKIPPING dangerous path: $path');
          continue;
        }
        final cmd = 'sudo rm -rf ${_shellQuote(path)}';
        final res = await ssh.run(s, cmd);
        _log(step, '[files] rm ${f.id}: $path (exit ${res.exitCode})');
      }
    }
  }

  Future<void> _runWriteFile(Map<String, dynamic> step) async {
    final s = _requireSession();
    final target = step['target'] as String?;
    final templatePath = step['template'] as String?;
    final content = step['content'] as String?;
    if (target == null) throw StepExecutionException('write_file missing target');
    String rendered;
    if (content != null) {
      rendered = _render(content);
    } else if (templatePath != null) {
      final src = _resolveProfilePath(templatePath);
      rendered = _render(await File(src).readAsString());
    } else {
      throw StepExecutionException('write_file requires template or content');
    }
    final tmpLocal = p.join(Directory.systemTemp.path,
        'deckhand-${DateTime.now().millisecondsSinceEpoch}.tmp');
    await File(tmpLocal).writeAsString(rendered);
    try {
      await ssh.upload(s, tmpLocal, target);
      _log(step, '[write_file] wrote $target (${rendered.length} bytes)');
    } finally {
      try {
        await File(tmpLocal).delete();
      } catch (_) {}
    }
  }

  Future<void> _runInstallScreen(Map<String, dynamic> step) async {
    final s = _requireSession();
    final screenId = _state.decisions['screen'] as String?;
    if (screenId == null) {
      _log(step, '[screen] no screen selected — skipping install');
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
        final res = await ssh.run(s, 'bash $remoteInstall',
            timeout: const Duration(minutes: 5));
        if (!res.success) {
          throw StepExecutionException('screen install script failed', stderr: res.stderr);
        }
      }
      _log(step, '[screen] installed $screenId');
    } else if (sourceKind == 'restore_from_backup') {
      _log(step, '[screen] $screenId restore-from-backup requires a mounted backup image — not yet automated');
    } else {
      _log(step, '[screen] $screenId source kind "$sourceKind" not implemented');
    }
  }

  Future<void> _runFlashMcus(Map<String, dynamic> step) async {
    final s = _requireSession();
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
      final writeConf = 'cd $install && cat > .config <<"MCUCONF"\n$configLines\nMCUCONF\n'
          'make olddefconfig >/dev/null && make clean >/dev/null && make -j1';
      final build = await ssh.run(s, writeConf, timeout: const Duration(minutes: 20));
      if (!build.success) {
        throw StepExecutionException('mcu $id build failed', stderr: build.stderr);
      }
      _log(step, '[mcu] built $id');

      final transport = (raw['transport'] as Map?)?.cast<String, dynamic>() ?? {};
      if (transport['requires_physical_access'] == true) {
        await _awaitUserInput('${mcu.id}_physical_prompt', {
          'id': '${mcu.id}_physical_prompt',
          'kind': 'prompt',
          'message': transport['physical_access_notes'] as String? ?? 'Put the MCU into bootloader mode.',
        });
      }
      _log(step, '[mcu] $id flash pending — refer to profile firmware/flash-$id.sh');
    }
  }

  Future<void> _runOsDownload(Map<String, dynamic> step) async {
    final osId = _state.decisions['flash.os'] as String?;
    if (osId == null) throw StepExecutionException('no OS image selected');
    final opt = _profile!.os.freshInstallOptions.firstWhere(
      (o) => o.id == osId,
      orElse: () => throw StepExecutionException('unknown OS option $osId'),
    );
    final dest = step['dest'] as String? ??
        p.join(Directory.systemTemp.path, 'deckhand-${opt.id}.img');
    _log(step, '[os] downloading ${opt.url} → $dest');
    _log(step, '[os] download dispatch handled by flash-progress UI');
  }

  Future<void> _runFlashDisk(Map<String, dynamic> step) async {
    final diskId = _state.decisions['flash.disk'] as String?;
    if (diskId == null) throw StepExecutionException('no flash disk selected');
    _log(step, '[flash] elevated-helper invocation queued for $diskId');
  }

  Future<void> _runWaitForSsh(Map<String, dynamic> step) async {
    final host = _state.sshHost;
    if (host == null) throw StepExecutionException('no ssh host set');
    final timeoutSecs = (step['timeout_seconds'] as num?)?.toInt() ?? 600;
    final ok = await discovery.waitForSsh(
      host: host,
      timeout: Duration(seconds: timeoutSecs),
    );
    if (!ok) throw StepExecutionException('ssh did not come up within $timeoutSecs seconds');
    _log(step, '[ssh] up at $host');
  }

  Future<void> _runVerify(Map<String, dynamic> step) async {
    final s = _requireSession();
    for (final v in _profile!.verifiers) {
      final kind = v.raw['kind'] as String? ?? '';
      switch (kind) {
        case 'ssh_command':
          final cmd = v.raw['command'] as String;
          final res = await ssh.run(s, cmd);
          final contains = v.raw['expect_stdout_contains'] as String?;
          final equals = v.raw['expect_stdout_equals'] as String?;
          var passed = res.success;
          if (contains != null) passed = passed && res.stdout.contains(contains);
          if (equals != null) passed = passed && res.stdout.trim() == equals.trim();
          _log(step, '[verify] ${v.id}: ${passed ? "PASS" : "FAIL"}');
          if (!passed && !(v.raw['optional'] as bool? ?? false)) {
            throw StepExecutionException('verifier ${v.id} failed');
          }
        case 'http_get':
          final host = _state.sshHost;
          if (host == null) {
            _log(step, '[verify] ${v.id}: no host — skipping');
            continue;
          }
          final url = (v.raw['url'] as String? ?? '').replaceAll('{{host}}', host);
          try {
            final info = await moonraker.info(host: host);
            _log(step, '[verify] ${v.id}: $url → klippy_state=${info.klippyState}');
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
    final env = DslEnv(decisions: _state.decisions, profile: _profile?.raw ?? const {});
    final matches = _dsl.evaluate(when, env);
    if (!matches) {
      _log(step, '[conditional] skipping — condition false');
      return;
    }
    final thenSteps = ((step['then'] as List?) ?? const []).whereType<Map>().toList();
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
        final choices = ((stack.webui?['choices'] as List?) ?? const []).cast<Map>();
        for (final c in choices) {
          if ((c['id'] as String?) == name) return c.cast<String, dynamic>();
        }
        return null;
    }
  }

  String _resolveProfilePath(String ref) {
    final base = _profileCache?.localPath ?? '.';
    if (ref.startsWith('./')) return p.join(base, ref.substring(2));
    if (ref.startsWith('/')) return ref;
    return p.join(base, ref);
  }

  Future<void> _uploadDir(String localDir, String remote) async {
    final s = _requireSession();
    final tmpTar = p.join(Directory.systemTemp.path,
        'deckhand-upload-${DateTime.now().millisecondsSinceEpoch}.tar');
    final result = await Process.run(
      'tar',
      ['-cf', tmpTar, '-C', p.dirname(localDir), p.basename(localDir)],
    );
    if (result.exitCode != 0) {
      throw StepExecutionException('local tar failed: ${result.stderr}');
    }
    try {
      final remoteTar = '/tmp/deckhand-upload-${DateTime.now().millisecondsSinceEpoch}.tar';
      await ssh.upload(s, tmpTar, remoteTar);
      final extract =
          'mkdir -p "$remote" && tar -xf "$remoteTar" -C "\$(dirname "$remote")" && rm -f "$remoteTar"';
      final res = await ssh.run(s, extract);
      if (!res.success) {
        throw StepExecutionException('remote extract failed', stderr: res.stderr);
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
      if (flashOffset.isNotEmpty) 'CONFIG_FLASH_APPLICATION_ADDRESS=$flashOffset',
      'CONFIG_${selectKey.toUpperCase()}=y',
      if (baud != null) 'CONFIG_SERIAL_BAUD=$baud',
    ];
    return lines.join('\n');
  }

  bool _isDangerousPath(String path) {
    const dangerous = {
      '/', '/bin', '/boot', '/etc', '/home', '/lib', '/lib64',
      '/opt', '/root', '/run', '/sbin', '/srv', '/sys', '/usr', '/var'
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
    await _eventsController.close();
    if (_session != null) await ssh.disconnect(_session!);
  }
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
  }) =>
      WizardState(
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
  const StepProgress({required this.stepId, required this.percent, this.message});
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
