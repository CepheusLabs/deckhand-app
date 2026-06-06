import 'dart:io';

import 'package:yaml/yaml.dart';

/// Parsed HITL scenario file. See `packaging/hitl/scenarios/` for
/// canonical examples. Schema version is checked at load time so a
/// driver upgrade can refuse a scenario authored for an older shape
/// rather than silently misinterpreting fields.
class Scenario {
  Scenario({
    required this.scenarioVersion,
    required this.profile,
    required this.flow,
    required this.printerHost,
    required this.sshUser,
    required this.sshPasswordEnv,
    required this.decisions,
    required this.expectedStepStatus,
    required this.expectedPorts,
    required this.expectedRemoteFiles,
    required this.maxDuration,
    required this.acceptHostKey,
  });

  factory Scenario.fromYaml(String text) {
    final doc = loadYaml(text);
    if (doc is! YamlMap) {
      throw const FormatException('scenario root must be a YAML map');
    }
    final ver = (doc['scenario_version'] as int?) ?? 0;
    if (ver != 1) {
      throw FormatException(
        'scenario_version $ver not supported (this driver speaks v1)',
      );
    }
    final printer = doc['printer'];
    if (printer is! YamlMap) {
      throw const FormatException('scenario.printer is required');
    }
    final ssh = printer['ssh'];
    if (ssh is! YamlMap) {
      throw const FormatException('scenario.printer.ssh is required');
    }

    final stepStatus = <String, String>{};
    final stepStatusRaw =
        (doc['expectations'] as YamlMap?)?['step_status'] as YamlMap?;
    if (stepStatusRaw != null) {
      stepStatusRaw.forEach((k, v) {
        stepStatus[k.toString()] = v.toString();
      });
    }

    final ports = <int, String>{};
    final portsRaw =
        (doc['expectations'] as YamlMap?)?['ports'] as YamlMap?;
    if (portsRaw != null) {
      portsRaw.forEach((k, v) {
        ports[int.parse(k.toString())] = v.toString();
      });
    }

    final remoteFiles = <ExpectedFile>[];
    final remoteFilesRaw =
        (doc['expectations'] as YamlMap?)?['remote_files'] as YamlList?;
    if (remoteFilesRaw != null) {
      for (final entry in remoteFilesRaw) {
        if (entry is YamlMap) {
          remoteFiles.add(ExpectedFile(
            path: entry['path'].toString(),
            mustExist: (entry['must_exist'] as bool?) ?? true,
          ));
        }
      }
    }

    final decisions = <String, dynamic>{};
    final decisionsRaw = doc['decisions'];
    if (decisionsRaw is YamlMap) {
      decisionsRaw.forEach((k, v) {
        decisions[k.toString()] = _toDart(v);
      });
    }

    final maxMin = (doc['max_duration_minutes'] as num?)?.toInt();
    return Scenario(
      scenarioVersion: ver,
      profile: doc['profile'].toString(),
      flow: doc['flow'].toString(),
      printerHost: printer['host'].toString(),
      sshUser: ssh['user'].toString(),
      sshPasswordEnv: (ssh['password_env'] as String?) ?? 'PRINTER_PASS',
      decisions: decisions,
      expectedStepStatus: stepStatus,
      expectedPorts: ports,
      expectedRemoteFiles: remoteFiles,
      maxDuration:
          maxMin == null ? null : Duration(minutes: maxMin),
      // Default false — strict host-key checking. Each scenario
      // YAML must opt into accept-on-first-use explicitly via
      // `accept_host_key: true`. The previous default-true was
      // friction-free for fresh-flash flows (where the printer's
      // host key legitimately changes on every reflash) but it
      // applied uniformly to every scenario, including ones where
      // a stable pinned key was the whole point. Now scenarios that
      // need TOFU say so loud at the YAML site.
      acceptHostKey: (ssh['accept_host_key'] as bool?) ?? false,
    );
  }

  /// Resolves the scenario's password env var. Returns null when the
  /// var is unset; the driver fails fast when SSH credentials are
  /// required but missing.
  String? resolvePassword() => Platform.environment[sshPasswordEnv];

  final int scenarioVersion;
  final String profile;
  final String flow;
  final String printerHost;
  final String sshUser;
  final String sshPasswordEnv;
  final Map<String, dynamic> decisions;
  final Map<String, String> expectedStepStatus;
  final Map<int, String> expectedPorts;
  final List<ExpectedFile> expectedRemoteFiles;
  final Duration? maxDuration;

  /// Whether the SSH connect should accept-on-first-use the
  /// printer's host key (vs. demanding a pinned fingerprint match).
  /// Defaults to false; a scenario opts in explicitly with
  /// `accept_host_key: true` (see the parser comment for rationale).
  final bool acceptHostKey;

  /// Whether the scenario asserts anything about the *result* of the run
  /// (open ports, remote files, or per-step statuses) rather than only
  /// that the flow executed. The HITL runner fails scenarios that don't,
  /// so an empty or typo'd expectations block can't gate a release on a
  /// run that proved nothing.
  bool get declaresOutcomeExpectations =>
      expectedStepStatus.isNotEmpty ||
      expectedPorts.isNotEmpty ||
      expectedRemoteFiles.isNotEmpty;
}

class ExpectedFile {
  const ExpectedFile({required this.path, required this.mustExist});
  final String path;
  final bool mustExist;
}

/// Recursively unwrap YamlMap / YamlList into plain Dart so callers
/// don't have to remember to use `.toString()` everywhere.
Object? _toDart(Object? v) {
  if (v is YamlMap) {
    return {
      for (final entry in v.entries) entry.key.toString(): _toDart(entry.value),
    };
  }
  if (v is YamlList) {
    return [for (final item in v) _toDart(item)];
  }
  return v;
}
