import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_flash/deckhand_flash.dart';
import 'package:deckhand_profiles/deckhand_profiles.dart';
import 'package:deckhand_ssh/deckhand_ssh.dart';
import 'package:path/path.dart' as p;

import 'headless_services.dart';
import 'scenario.dart';

/// Phase 2 HITL driver: wires a real [WizardController] against the
/// sidecar + a real printer, replays the scenario's decisions, runs
/// `startExecution`, and evaluates the scenario's expectations after
/// the flow completes (or fails).
///
/// Compared to v1 (sidecar-handshake-only), this exercises the
/// full state machine: profile fetch, SSH connect, decision graph,
/// per-step execution, on-printer run-state writes. A regression
/// that lives entirely in the wizard (e.g. a step kind that no
/// longer fires its post-check) shows up here.
class ScenarioRunner {
  ScenarioRunner({
    required this.scenario,
    required this.sidecarPath,
    this.helperPath,
    required this.outputDir,
    this.bailOnFirstFailure = false,
    Logger? logger,
  }) : _log = logger ?? _StdoutLogger();

  final Scenario scenario;
  final String sidecarPath;
  final String? helperPath;
  final String outputDir;

  /// When true, the runner stops at the first failed assertion and
  /// returns immediately. Default false: collect every signal, write
  /// the manifest, exit at the end. The CLI's
  /// `--bail-on-first-failure` flag toggles this.
  final bool bailOnFirstFailure;

  final Logger _log;
  bool _bailed = false;

  /// Run the scenario end-to-end. Throws no exceptions — every
  /// failure becomes an [_AssertionResult] in the returned report.
  /// Caller picks the exit code based on `report.failedCount`.
  Future<RunReport> run() async {
    await Directory(outputDir).create(recursive: true);
    final results = <AssertionResult>[];
    final started = DateTime.now();

    void record(String name, bool ok, String detail) {
      results.add(AssertionResult(name: name, ok: ok, detail: detail));
      _log.line('${ok ? 'PASS' : 'FAIL'}  $name — $detail');
      if (!ok && bailOnFirstFailure) {
        _bailed = true;
      }
    }

    /// Convenience for the post-execution phase. The driver runs every
    /// section of the post-flow checklist (ports, files, run-state)
    /// even if a single port assertion fails — but bail-on-first-fail
    /// short-circuits the whole batch on the first miss.
    bool shouldKeepGoing() => !_bailed;

    SidecarClient? sidecar;
    DartsshService? sshService;
    SshSession? sshSession;
    HeadlessSecurityService? security;
    DeckhandLogger? sidecarLogger;

    try {
      // ----------------------------------------------------------
      // 1. Boot sidecar. Stderr from the sidecar process is routed
      // through DeckhandLogger into <output>/sidecar.jsonl so a
      // failed run preserves the sidecar's own diagnostic output
      // for post-mortem. Without this, sidecar stderr would land
      // on the runner's stderr and disappear once the runner exits.
      sidecarLogger = DeckhandLogger(
        logsDir: outputDir,
        sessionName: 'sidecar',
      );
      await sidecarLogger.init();
      sidecar = SidecarClient(binaryPath: sidecarPath, logger: sidecarLogger);
      try {
        await sidecar.start();
        record('sidecar.start', true, 'sidecar responded to ping');
      } on Object catch (e) {
        record('sidecar.start', false, 'failed: $e');
        return _finalize(results, started);
      }

      // ----------------------------------------------------------
      // 2. Doctor probe — fast pre-flight; failures here are not
      // a hard stop, they're context for any later failure.
      try {
        final res = await sidecar.call('doctor.run', const {});
        final passed = res['passed'] as bool? ?? false;
        record(
          'doctor.run',
          passed,
          passed ? 'all checks passed' : 'one or more FAILs (see report)',
        );
        await File(
          p.join(outputDir, 'doctor.txt'),
        ).writeAsString(res['report']?.toString() ?? '');
      } on Object catch (e) {
        record('doctor.run', false, 'rpc failed: $e');
      }

      // ----------------------------------------------------------
      // 3. Wire services.
      final paths = DeckhandPaths(
        cacheDir: p.join(outputDir, 'cache'),
        stateDir: p.join(outputDir, 'state'),
        logsDir: p.join(outputDir, 'logs'),
        settingsFile: p.join(outputDir, 'settings.json'),
      );
      await Directory(paths.cacheDir).create(recursive: true);
      await Directory(paths.stateDir).create(recursive: true);
      await Directory(paths.logsDir).create(recursive: true);

      security = HeadlessSecurityService(stateDir: paths.stateDir);
      sshService = DartsshService(security: security);

      final profiles = SidecarProfileService(
        sidecar: sidecar,
        paths: paths,
        security: security,
        // localProfilesDir: env DECKHAND_PROFILES_LOCAL takes
        // precedence inside the service. CI runs typically point
        // at a checked-out deckhand-profiles tree.
      );
      final flash = SidecarFlashService(sidecar);
      final upstream = SidecarUpstreamService(
        sidecar: sidecar,
        security: security,
      );
      final elevated = helperPath == null
          ? null
          : ProcessElevatedHelperService(helperPath: helperPath!);
      final snapshotsDir = p.join(paths.stateDir, 'snapshots');
      await Directory(snapshotsDir).create(recursive: true);
      final archiveService = DartsshArchiveService(ssh: sshService);

      // ----------------------------------------------------------
      // 4. Build controller. The version string lands in the
      // on-printer run-state file so the rig manifest can correlate
      // a failed run to the deckhand release that produced it.
      // Sourced from `--dart-define=DECKHAND_VERSION=...` at build
      // time; the workflow wires that to the same CalVer string the
      // installer artifacts carry.
      const hitlVersion = String.fromEnvironment(
        'DECKHAND_VERSION',
        defaultValue: 'hitl-dev',
      );
      final controller = WizardController(
        profiles: profiles,
        ssh: sshService,
        flash: flash,
        discovery: StubDiscoveryService(),
        moonraker: const StubMoonrakerService(),
        upstream: upstream,
        security: security,
        elevatedHelper: elevated,
        archive: archiveService,
        snapshotsDir: snapshotsDir,
        deckhandVersion: hitlVersion,
      );

      // ----------------------------------------------------------
      // 5. Load profile.
      try {
        await controller.loadProfile(scenario.profile);
        record(
          'profile.load',
          true,
          'loaded ${scenario.profile} (commit unset for local override)',
        );
      } on Object catch (e) {
        record('profile.load', false, 'failed: $e');
        return _finalize(results, started);
      }

      // ----------------------------------------------------------
      // 6. SSH connect.
      final pwd = scenario.resolvePassword();
      if (pwd == null || pwd.isEmpty) {
        record(
          'ssh.password_env',
          false,
          'env ${scenario.sshPasswordEnv} is empty',
        );
        return _finalize(results, started);
      }
      try {
        await controller.connectSshWithPassword(
          host: scenario.printerHost,
          user: scenario.sshUser,
          password: pwd,
          acceptHostKey: scenario.acceptHostKey,
        );
        sshSession = controller.sshSession;
        record(
          'ssh.connect',
          sshSession != null,
          'connected to ${scenario.printerHost} as ${scenario.sshUser} '
              '(acceptHostKey=${scenario.acceptHostKey})',
        );
      } on Object catch (e) {
        record('ssh.connect', false, 'failed: $e');
        return _finalize(results, started);
      }

      // ----------------------------------------------------------
      // 7. Set flow + decisions.
      final flowKind = _flowFromName(scenario.flow);
      if (flowKind == null) {
        record(
          'scenario.flow',
          false,
          'unknown flow ${scenario.flow}; expected stock_keep or fresh_flash',
        );
        return _finalize(results, started);
      }
      controller.setFlow(flowKind);
      record('scenario.flow', true, scenario.flow);

      var decisionsApplied = 0;
      try {
        for (final entry in flattenDecisions(scenario.decisions).entries) {
          await controller.setDecision(entry.key, entry.value);
          decisionsApplied++;
        }
        record('decisions.apply', true, 'applied $decisionsApplied decisions');
      } on Object catch (e) {
        record('decisions.apply', false, 'failed after $decisionsApplied: $e');
        return _finalize(results, started);
      }

      // ----------------------------------------------------------
      // 8. Run flow. Subscribe to events for the artifact log;
      // UserInputRequired is treated as a scenario error (HITL is
      // non-interactive — every step that prompts must be answered
      // by a decision in the YAML).
      final flowLog = StringBuffer();
      void writeEvent(String line) {
        final stamped = '${DateTime.now().toUtc().toIso8601String()}  $line';
        flowLog.writeln(stamped);
        _log.line(stamped);
      }

      final encounteredUserInputs = <String>[];
      final subscription = controller.events.listen((e) {
        switch (e) {
          case StepStarted(:final stepId):
            writeEvent('> step $stepId started');
          case StepCompleted(:final stepId):
            writeEvent('  step $stepId completed');
          case StepFailed(:final stepId, :final error):
            writeEvent('  step $stepId FAILED: $error');
          case StepLog(:final line):
            writeEvent('    $line');
          case StepWarning(:final stepId, :final message):
            writeEvent('  step $stepId WARN: $message');
          case StepProgress(:final percent, :final message):
            final percentLabel = percent == null
                ? 'unknown'
                : '${(percent * 100).toStringAsFixed(0)}%';
            writeEvent('  step progress $percentLabel ${message ?? ''}');
          case UserInputRequired(:final stepId):
            encounteredUserInputs.add(stepId);
            writeEvent(
              '  step $stepId waiting on user input — '
              'aborting (scenarios must decide every step up-front)',
            );
            // Two-step abort: resolve the pending input so the
            // current step's await unblocks (otherwise it deadlocks),
            // then signal cancellation so the loop bails before the
            // next step. startExecution throws WizardCancelledException
            // which we catch below.
            controller.resolveUserInput(stepId, null);
            controller.cancelExecution(
              reason: 'scenario did not pre-decide step "$stepId"',
            );
          case _:
            break;
        }
      });

      var executionOk = false;
      Object? executionError;
      try {
        await controller.startExecution();
        executionOk = true;
      } on WizardCancelledException catch (e) {
        // Cancellation is its own signal — record the reason but
        // don't double-count the missing-input failure (already
        // recorded by the event listener).
        executionError = e;
      } on Object catch (e) {
        executionError = e;
      } finally {
        await subscription.cancel();
      }

      await File(
        p.join(outputDir, 'flow.log'),
      ).writeAsString(flowLog.toString());

      if (encounteredUserInputs.isNotEmpty) {
        record(
          'flow.no_user_input_required',
          false,
          'scenarios must decide every step up-front; missing: '
              '${encounteredUserInputs.join(", ")}',
        );
      } else {
        record('flow.no_user_input_required', true, 'no interactive prompts');
      }

      record(
        'flow.execute',
        executionOk,
        executionOk ? 'completed' : 'failed: $executionError',
      );

      // ----------------------------------------------------------
      // 9. Post-execution probes.
      // Per-port TCP reachability.
      for (final entry in scenario.expectedPorts.entries) {
        if (!shouldKeepGoing()) break;
        final port = entry.key;
        final want = entry.value;
        final reachable = await _tcpConnect(scenario.printerHost, port);
        final wantOpen = want == 'open';
        final ok = wantOpen == reachable;
        record(
          'port.$port',
          ok,
          reachable ? 'reachable (wanted=$want)' : 'unreachable (wanted=$want)',
        );
      }

      // Per-file existence — uses the SSH session we already have.
      for (final ef in scenario.expectedRemoteFiles) {
        if (!shouldKeepGoing()) break;
        try {
          final r = await sshService.run(
            sshSession!,
            'test -e ${_shellQuote(ef.path)} && echo yes || echo no',
            timeout: const Duration(seconds: 15),
          );
          final exists = r.stdout.trim() == 'yes';
          final ok = exists == ef.mustExist;
          record(
            'remote_file.${_safeName(ef.path)}',
            ok,
            'exists=$exists, expected=${ef.mustExist}',
          );
        } on Object catch (e) {
          record(
            'remote_file.${_safeName(ef.path)}',
            false,
            'probe failed: $e',
          );
        }
      }

      // Run-state — fetched from the printer and matched against
      // expected step statuses. The on-printer file is the canonical
      // record of what got done; this asserts the wizard wrote it.
      if (scenario.expectedStepStatus.isNotEmpty && shouldKeepGoing()) {
        try {
          final store = RunStateStore(ssh: sshService);
          final state = await store.load(sshSession!);
          if (state == null) {
            record(
              'run_state.present',
              false,
              '~/.deckhand/run-state.json missing or unreadable',
            );
          } else {
            record(
              'run_state.present',
              true,
              '${state.steps.length} step(s) recorded',
            );
            await File(p.join(outputDir, 'run_state.json')).writeAsString(
              const JsonEncoder.withIndent('  ').convert(state.toJson()),
            );
            for (final entry in scenario.expectedStepStatus.entries) {
              final step = state.lastFor(entry.key);
              final actual = step?.status.wireName ?? '<missing>';
              final ok = actual == entry.value;
              record(
                'step_status.${entry.key}',
                ok,
                'actual=$actual, expected=${entry.value}',
              );
            }
          }
        } on Object catch (e) {
          record('run_state.present', false, 'fetch failed: $e');
        }
      }

      // Wall-time drift detection.
      final elapsed = DateTime.now().difference(started);
      if (scenario.maxDuration != null) {
        final ok = elapsed <= scenario.maxDuration!;
        record(
          'duration.under_cap',
          ok,
          'took $elapsed (cap ${scenario.maxDuration})',
        );
      }
    } finally {
      try {
        if (sshSession != null && sshService != null) {
          await sshService.disconnect(sshSession);
        }
      } on Object {
        /* best-effort */
      }
      try {
        await sidecar?.shutdown();
      } on Object {
        /* best-effort */
      }
      await security?.dispose();
      try {
        await sidecarLogger?.close();
      } on Object {
        /* best-effort */
      }
    }

    return _finalize(results, started);
  }

  RunReport _finalize(List<AssertionResult> results, DateTime started) {
    final report = RunReport(
      results: results,
      startedAt: started,
      finishedAt: DateTime.now(),
    );
    final manifest = <String, Object?>{
      'schema': 'deckhand.hitl_manifest/1',
      'profile': scenario.profile,
      'flow': scenario.flow,
      'started_at': started.toUtc().toIso8601String(),
      'finished_at': DateTime.now().toUtc().toIso8601String(),
      'results': [
        for (final r in results)
          {'name': r.name, 'ok': r.ok, 'detail': r.detail},
      ],
      'failed_count': report.failedCount,
    };
    File(
      p.join(outputDir, 'manifest.json'),
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(manifest));
    return report;
  }

  static Future<bool> _tcpConnect(String host, int port) async {
    try {
      final s = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 5),
      );
      s.destroy();
      return true;
    } on Object {
      return false;
    }
  }

  static String _shellQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";
  static String _safeName(String s) =>
      s.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
}

/// Flatten a nested decisions map (as it appears in scenario YAML)
/// into the dotted-path keys the wizard controller stores. Public so
/// tests can pin the encoding.
Map<String, Object> flattenDecisions(Map<String, dynamic> input) {
  final out = <String, Object>{};
  void recurse(String prefix, Object? value) {
    if (value is Map) {
      for (final entry in value.entries) {
        final key = entry.key.toString();
        final next = prefix.isEmpty ? key : '$prefix.$key';
        recurse(next, entry.value);
      }
      return;
    }
    if (prefix.isEmpty || value == null) return;
    out[prefix] = value;
  }

  recurse('', input);
  return out;
}

WizardFlow? _flowFromName(String name) {
  switch (name) {
    case 'stock_keep':
    case 'stockKeep':
      return WizardFlow.stockKeep;
    case 'fresh_flash':
    case 'freshFlash':
      return WizardFlow.freshFlash;
    default:
      return null;
  }
}

class AssertionResult {
  AssertionResult({required this.name, required this.ok, required this.detail});

  final String name;
  final bool ok;
  final String detail;
}

class RunReport {
  RunReport({
    required this.results,
    required this.startedAt,
    required this.finishedAt,
  });

  final List<AssertionResult> results;
  final DateTime startedAt;
  final DateTime finishedAt;

  int get failedCount => results.where((r) => !r.ok).length;
  Duration get elapsed => finishedAt.difference(startedAt);
}

abstract class Logger {
  void line(String text);
}

class _StdoutLogger implements Logger {
  @override
  void line(String text) => stdout.writeln(text);
}
