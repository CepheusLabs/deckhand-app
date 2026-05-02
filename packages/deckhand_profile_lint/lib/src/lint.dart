import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:json_schema/json_schema.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

enum LintSeverity { error, warning, info }

class LintFinding {
  LintFinding(this.severity, this.path, this.message);
  final LintSeverity severity;
  final String path;
  final String message;
}

class LintResult {
  LintResult(this.file, this.profileId, this.findings);
  final String file;
  final String? profileId;
  final List<LintFinding> findings;
}

class LintReport {
  LintReport(this.results, {required this.strict});
  final List<LintResult> results;
  final bool strict;

  bool get hasErrors {
    for (final r in results) {
      for (final f in r.findings) {
        if (f.severity == LintSeverity.error) return true;
        if (strict && f.severity == LintSeverity.warning) return true;
      }
    }
    return false;
  }

  void write(IOSink sink) {
    var errors = 0;
    var warnings = 0;
    for (final r in results) {
      if (r.findings.isEmpty) {
        sink.writeln('OK      ${r.file}');
        continue;
      }
      for (final f in r.findings) {
        final tag = switch (f.severity) {
          LintSeverity.error => 'ERROR  ',
          LintSeverity.warning => 'WARN   ',
          LintSeverity.info => 'INFO   ',
        };
        sink.writeln('$tag ${r.file}${f.path.isEmpty ? '' : ':${f.path}'} — ${f.message}');
        if (f.severity == LintSeverity.error) errors++;
        if (f.severity == LintSeverity.warning) warnings++;
      }
    }
    sink.writeln('---');
    sink.writeln('${results.length} profile(s) scanned, $errors error(s), $warnings warning(s).');
  }
}

class LintUsageException implements Exception {
  LintUsageException(this.message);
  final String message;
}

Future<LintReport> runProfileLint(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('root', help: 'deckhand-profiles checkout root', mandatory: true)
    ..addOption('schema', help: 'Path to profile.schema.json (defaults to <root>/schema/profile.schema.json)')
    ..addFlag('strict', help: 'Treat warnings as errors.', defaultsTo: false)
    ..addFlag('help', abbr: 'h', negatable: false);

  ArgResults args;
  try {
    args = parser.parse(argv);
  } on ArgParserException catch (e) {
    throw LintUsageException(e.message);
  }
  if (args['help'] as bool) {
    throw LintUsageException('Usage: deckhand-profile-lint --root <dir>\n${parser.usage}');
  }
  final root = Directory(args['root'] as String);
  if (!root.existsSync()) {
    throw LintUsageException('root does not exist: ${root.path}');
  }
  final schemaPath = (args['schema'] as String?) ??
      p.join(root.path, 'schema', 'profile.schema.json');
  final schemaFile = File(schemaPath);
  if (!schemaFile.existsSync()) {
    throw LintUsageException('schema not found: $schemaPath');
  }
  final schemaData = jsonDecode(await schemaFile.readAsString()) as Object;
  final schema = JsonSchema.create(schemaData);

  // Load registry.yaml to cross-reference profile_id listings.
  final registryFile = File(p.join(root.path, 'registry.yaml'));
  final registryIds = <String>{};
  if (registryFile.existsSync()) {
    final doc = loadYaml(await registryFile.readAsString());
    if (doc is Map && doc['profiles'] is List) {
      for (final entry in doc['profiles'] as List) {
        if (entry is Map && entry['profile_id'] is String) {
          registryIds.add(entry['profile_id'] as String);
        }
      }
    }
  }

  // Walk printers/<id>/profile.yaml.
  final printersDir = Directory(p.join(root.path, 'printers'));
  if (!printersDir.existsSync()) {
    throw LintUsageException('no printers/ directory under ${root.path}');
  }

  final results = <LintResult>[];
  final seenIds = <String>{};

  final entries = printersDir
      .listSync()
      .whereType<Directory>()
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final dir in entries) {
    final rel = p.relative(dir.path, from: root.path);
    final profileFile = File(p.join(dir.path, 'profile.yaml'));
    if (!profileFile.existsSync()) {
      results.add(LintResult(
        rel,
        null,
        [LintFinding(LintSeverity.error, '', 'missing profile.yaml')],
      ));
      continue;
    }
    final findings = <LintFinding>[];
    final raw = await profileFile.readAsString();
    Object? parsed;
    try {
      parsed = _toPlain(loadYaml(raw));
    } on YamlException catch (e) {
      findings.add(LintFinding(LintSeverity.error, '', 'YAML parse: ${e.message}'));
      results.add(LintResult(rel, null, findings));
      continue;
    }
    if (parsed is! Map<String, dynamic>) {
      findings.add(LintFinding(LintSeverity.error, '', 'top level is not a mapping'));
      results.add(LintResult(rel, null, findings));
      continue;
    }
    String? profileId;
    final idVal = parsed['profile_id'];
    if (idVal is String) profileId = idVal;

    // Schema validation.
    final vres = schema.validate(parsed);
    for (final err in vres.errors) {
      findings.add(LintFinding(
        LintSeverity.error,
        err.instancePath.isEmpty ? '' : err.instancePath,
        err.message,
      ));
    }

    // Safety cross-checks beyond the schema.
    if (profileId != null) {
      final folder = p.basename(dir.path);
      if (folder != profileId) {
        findings.add(LintFinding(
          LintSeverity.error,
          'profile_id',
          'folder name "$folder" does not match profile_id "$profileId"',
        ));
      }
      if (!seenIds.add(profileId)) {
        findings.add(LintFinding(LintSeverity.error, 'profile_id',
            'duplicate profile_id "$profileId"'));
      }
      if (registryIds.isNotEmpty && !registryIds.contains(profileId)) {
        findings.add(LintFinding(LintSeverity.error, 'profile_id',
            'profile_id "$profileId" not listed in registry.yaml'));
      }
    }

    if (parsed['status'] == 'stub') {
      findings.add(LintFinding(
        LintSeverity.warning,
        'status',
        'profile still marked "stub" — release gating will refuse to tag it',
      ));
    }

    // URL safety: every url field must be https, every sha256 must be a
    // 64-char hex. We walk generically because the schema nests urls
    // under many shapes (firmware_variants, stack components, etc).
    _walkUrlsAndHashes(parsed, '', findings);

    // Idempotency contract: every executable step in a flow must
    // either declare an `idempotency` block (pre-check / resume /
    // post-check) per docs/STEP-IDEMPOTENCY.md, or carry an
    // explicit `safe_to_rerun: true` for steps that are no-op-on-
    // retry by their nature (pure logging, prompts, etc.).
    _walkIdempotency(parsed, findings);

    results.add(LintResult(rel, profileId, findings));
  }

  return LintReport(results, strict: args['strict'] as bool);
}

/// Step kinds that have built-in idempotency baked into the
/// controller (per [docs/STEP-IDEMPOTENCY.md] — apt_install,
/// service_install, etc.). The controller's wrapper handles
/// pre-check + resume; profiles don't need to declare anything
/// extra. New kinds added here must also be added to the
/// controller's idempotency map.
const _kindsWithBuiltInIdempotency = <String>{
  'wait_for_ssh',
  'os_download',
  'verify',
  'conditional',
  'install_marker',
  'snapshot_archive',
};

/// Step kinds that are interactive UI prompts — they have no
/// printer-side side effect, so re-running them after a resume is
/// always safe.
const _interactiveStepKinds = <String>{
  'prompt',
  'choose_one',
  'disk_picker',
};

/// Walk every flow's step list and emit a warning for each step
/// that fails the idempotency contract.
void _walkIdempotency(Map<String, dynamic> profile, List<LintFinding> out) {
  final flows = profile['flows'];
  if (flows is! Map) return;
  flows.forEach((flowName, flow) {
    if (flow is! Map) return;
    final steps = flow['steps'];
    if (steps is! List) return;
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      if (step is! Map) continue;
      final kind = step['kind']?.toString() ?? '';
      final id = step['id']?.toString() ?? '<unnamed>';
      final path = 'flows.$flowName.steps[$i] ($id, kind=$kind)';

      // Built-in or interactive: no profile declaration needed.
      if (_kindsWithBuiltInIdempotency.contains(kind)) continue;
      if (_interactiveStepKinds.contains(kind)) continue;

      // Explicit opt-out: the profile author asserted the step is
      // safe to rerun blindly (e.g. a pure logging step).
      if (step['safe_to_rerun'] == true) continue;

      // Otherwise the step MUST declare an idempotency block with at
      // least a pre_check or a resume strategy. Missing both is a
      // warning — strict mode (used by deckhand-profiles CI) treats it
      // as an error so a profile can't ship without the contract.
      final idem = step['idempotency'];
      if (idem is! Map ||
          (idem['pre_check'] == null && idem['resume'] == null)) {
        out.add(LintFinding(
          LintSeverity.warning,
          path,
          'step has no idempotency block (need pre_check + resume, '
          'or set safe_to_rerun: true). See '
          'docs/STEP-IDEMPOTENCY.md.',
        ));
      }
    }
  });
}

void _walkUrlsAndHashes(Object? node, String path, List<LintFinding> out) {
  if (node is Map<String, dynamic>) {
    // Only flag `url` as needing https:// when this same node ALSO carries
    // a `sha256` — i.e. when it's a download we're going to integrity-check
    // (fresh_install_options, firmware-blob fetches, etc.). Verifier URLs
    // that hit Moonraker / Klippy on the printer's LAN are http:// by
    // design (Moonraker doesn't ship TLS, the trusted_clients list bounds
    // the access scope, the endpoint is templated against {{host}}).
    final hasSha = node['sha256'] is String;
    node.forEach((key, value) {
      final child = path.isEmpty ? key : '$path.$key';
      if (key == 'url' && value is String && hasSha) {
        if (!value.startsWith('https://')) {
          out.add(LintFinding(LintSeverity.error, child,
              'url must be https:// (this node has a sha256 — '
              'it\'s a download), got "$value"'));
        }
      }
      if (key == 'sha256' && value is String) {
        if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
          out.add(LintFinding(LintSeverity.error, child,
              'sha256 must be 64 hex chars, got "${value.length} chars"'));
        }
      }
      _walkUrlsAndHashes(value, child, out);
    });
  } else if (node is List) {
    for (var i = 0; i < node.length; i++) {
      _walkUrlsAndHashes(node[i], '$path[$i]', out);
    }
  }
}

Object? _toPlain(Object? node) {
  if (node is YamlMap) {
    final m = <String, dynamic>{};
    node.forEach((k, v) => m[k.toString()] = _toPlain(v));
    return m;
  }
  if (node is YamlList) {
    return node.map(_toPlain).toList();
  }
  return node;
}
