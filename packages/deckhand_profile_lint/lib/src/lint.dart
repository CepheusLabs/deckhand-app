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
        sink.writeln(
          '$tag ${r.file}${f.path.isEmpty ? '' : ':${f.path}'} — ${f.message}',
        );
        if (f.severity == LintSeverity.error) errors++;
        if (f.severity == LintSeverity.warning) warnings++;
      }
    }
    sink.writeln('---');
    sink.writeln(
      '${results.length} profile(s) scanned, $errors error(s), $warnings warning(s).',
    );
  }
}

class LintUsageException implements Exception {
  LintUsageException(this.message);
  final String message;
}

Future<LintReport> runProfileLint(List<String> argv) async {
  final parser = ArgParser()
    ..addOption(
      'root',
      help: 'deckhand-profiles checkout root',
      mandatory: true,
    )
    ..addOption(
      'schema',
      help:
          'Path to profile.schema.json (defaults to <root>/schema/profile.schema.json)',
    )
    ..addFlag('strict', help: 'Treat warnings as errors.', defaultsTo: false)
    ..addFlag(
      'regenerate-registry',
      help:
          'Regenerate registry.yaml from each printers/<id>/profile.yaml '
          'and exit. Authors run this after editing a profile; CI runs '
          'without the flag and fails if the on-disk registry has '
          'drifted.',
      defaultsTo: false,
    )
    ..addFlag('help', abbr: 'h', negatable: false);

  ArgResults args;
  try {
    args = parser.parse(argv);
  } on ArgParserException catch (e) {
    throw LintUsageException(e.message);
  }
  if (args['help'] as bool) {
    throw LintUsageException(
      'Usage: deckhand-profile-lint --root <dir>\n${parser.usage}',
    );
  }
  final root = Directory(args['root'] as String);
  if (!root.existsSync()) {
    throw LintUsageException('root does not exist: ${root.path}');
  }

  // --regenerate-registry short-circuits the rest of the lint and just
  // rewrites registry.yaml from the profile.yaml files. Used by
  // contributors after they edit `status` / `display_name` / etc on a
  // profile so they don't have to hand-edit two files.
  if (args['regenerate-registry'] as bool) {
    final generated = await _generateRegistry(root);
    final outFile = File(p.join(root.path, 'registry.yaml'));
    await outFile.writeAsString(generated);
    final report = LintReport([
      LintResult('registry.yaml', null, [
        LintFinding(
          LintSeverity.info,
          '',
          'regenerated from printers/*/profile.yaml '
              '(${_countProfiles(root)} entries)',
        ),
      ]),
    ], strict: args['strict'] as bool);
    return report;
  }
  final schemaPath =
      (args['schema'] as String?) ??
      p.join(root.path, 'schema', 'profile.schema.json');
  final schemaFile = File(schemaPath);
  if (!schemaFile.existsSync()) {
    throw LintUsageException('schema not found: $schemaPath');
  }
  final schemaData = jsonDecode(await schemaFile.readAsString()) as Object;
  final schema = JsonSchema.create(schemaData);

  // Load registry.yaml to cross-reference id listings AND to detect
  // drift between the per-profile yamls and the registry's duplicated
  // metadata fields (display_name / manufacturer / model / status). The
  // previous version looked for `entry['profile_id']` while the registry
  // actually uses `id`, so the cross-check silently returned an empty
  // set and drift went undetected — that's how Arco's registry status
  // got stuck on `alpha` after profile.yaml moved to `beta`.
  final registryFile = File(p.join(root.path, 'registry.yaml'));
  final registryEntries = <String, Map<String, dynamic>>{};
  if (registryFile.existsSync()) {
    final doc = loadYaml(await registryFile.readAsString());
    if (doc is Map && doc['profiles'] is List) {
      for (final entry in doc['profiles'] as List) {
        if (entry is Map && entry['id'] is String) {
          registryEntries[entry['id'] as String] = (_toPlain(entry) as Map)
              .cast<String, dynamic>();
        }
      }
    }
  }
  final registryIds = registryEntries.keys.toSet();

  // Walk printers/<id>/profile.yaml.
  final printersDir = Directory(p.join(root.path, 'printers'));
  if (!printersDir.existsSync()) {
    throw LintUsageException('no printers/ directory under ${root.path}');
  }

  final results = <LintResult>[];
  final seenIds = <String>{};

  final entries = printersDir.listSync().whereType<Directory>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final dir in entries) {
    final rel = p.relative(dir.path, from: root.path);
    final profileFile = File(p.join(dir.path, 'profile.yaml'));
    if (!profileFile.existsSync()) {
      results.add(
        LintResult(rel, null, [
          LintFinding(LintSeverity.error, '', 'missing profile.yaml'),
        ]),
      );
      continue;
    }
    final findings = <LintFinding>[];
    final raw = await profileFile.readAsString();
    Object? parsed;
    try {
      parsed = _toPlain(loadYaml(raw));
    } on YamlException catch (e) {
      findings.add(
        LintFinding(LintSeverity.error, '', 'YAML parse: ${e.message}'),
      );
      results.add(LintResult(rel, null, findings));
      continue;
    }
    if (parsed is! Map<String, dynamic>) {
      findings.add(
        LintFinding(LintSeverity.error, '', 'top level is not a mapping'),
      );
      results.add(LintResult(rel, null, findings));
      continue;
    }
    String? profileId;
    final idVal = parsed['profile_id'];
    if (idVal is String) profileId = idVal;

    // Schema validation.
    final vres = schema.validate(parsed);
    for (final err in vres.errors) {
      findings.add(
        LintFinding(
          LintSeverity.error,
          err.instancePath.isEmpty ? '' : err.instancePath,
          err.message,
        ),
      );
    }

    // Safety cross-checks beyond the schema.
    if (profileId != null) {
      final folder = p.basename(dir.path);
      if (folder != profileId) {
        findings.add(
          LintFinding(
            LintSeverity.error,
            'profile_id',
            'folder name "$folder" does not match profile_id "$profileId"',
          ),
        );
      }
      if (!seenIds.add(profileId)) {
        findings.add(
          LintFinding(
            LintSeverity.error,
            'profile_id',
            'duplicate profile_id "$profileId"',
          ),
        );
      }
      if (registryIds.isNotEmpty && !registryIds.contains(profileId)) {
        findings.add(
          LintFinding(
            LintSeverity.error,
            'profile_id',
            'profile_id "$profileId" not listed in registry.yaml',
          ),
        );
      }
      // Drift check: registry.yaml duplicates a handful of metadata
      // fields from profile.yaml. They MUST agree, or the picker
      // (which reads from registry) shows stale info while the rest
      // of the wizard (which reads from profile) shows fresh info —
      // exactly the Arco alpha/beta confusion. Run `--regenerate-
      // registry` after editing a profile to keep them in sync.
      final regEntry = registryEntries[profileId];
      if (regEntry != null) {
        const mirroredFields = <String>[
          'display_name',
          'manufacturer',
          'model',
          'status',
        ];
        for (final field in mirroredFields) {
          final profileVal = parsed[field];
          final registryVal = regEntry[field];
          if (profileVal != registryVal) {
            findings.add(
              LintFinding(
                LintSeverity.error,
                field,
                'registry.yaml says "$registryVal" but profile.yaml says '
                '"$profileVal" — run `deckhand-profile-lint '
                '--root <repo> --regenerate-registry` to sync',
              ),
            );
          }
        }
        // Derived spec-card fields. The registry value should equal
        // what the generator would synthesize from the current
        // profile.yaml — drift here means someone hand-edited the
        // registry, which the file's header explicitly forbids.
        final derived = <String, String?>{
          'sbc': _deriveSbc(parsed),
          'kinematics': _deriveKinematics(parsed),
          'mcu': _deriveMcu(parsed),
          'extras': parsed['picker_extras'] as String?,
        };
        derived.forEach((field, expected) {
          final actual = regEntry[field];
          if (expected != actual) {
            findings.add(
              LintFinding(
                LintSeverity.error,
                field,
                'registry.yaml says "$actual" but profile.yaml derives '
                '"$expected" — run `deckhand-profile-lint '
                '--root <repo> --regenerate-registry` to sync',
              ),
            );
          }
        });
      }
    }

    if (parsed['status'] == 'stub') {
      findings.add(
        LintFinding(
          LintSeverity.warning,
          'status',
          'profile still marked "stub" — release gating will refuse to tag it',
        ),
      );
    }

    // URL safety: every url field must be https, every sha256 must be a
    // 64-char hex. We walk generically because the schema nests urls
    // under many shapes (firmware_variants, stack components, etc).
    _walkUrlsAndHashes(parsed, '', findings);

    // Snapshot capture paths are passed to remote tar. The runtime
    // command now inserts `--`, but lint still rejects option-looking
    // profile paths so bad manifests are caught before shipping.
    _walkSnapshotPaths(parsed, findings);

    // Profile-declared git sources and script interpreters are
    // eventually executed on the printer over SSH. Shell quoting is
    // necessary but not sufficient there: option-looking refs/repos
    // and multi-word interpreters can still alter command semantics.
    _walkCommandSurfaces(parsed, findings);

    // Runtime support gate: profile schema may allow forward-looking
    // constructs before the app can execute them. Catch those in lint
    // so a tagged profile cannot fail mid-install with "not
    // implemented" after the user already committed to a flow.
    _walkUnsupportedRuntimeFeatures(parsed, findings);

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
const _interactiveStepKinds = <String>{'prompt', 'choose_one', 'disk_picker'};

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
        out.add(
          LintFinding(
            LintSeverity.warning,
            path,
            'step has no idempotency block (need pre_check + resume, '
            'or set safe_to_rerun: true). See '
            'docs/STEP-IDEMPOTENCY.md.',
          ),
        );
        continue;
      }
      _validateIdempotencyBlock(idem, path, out);
    }
  });
}

const _resumeStrategies = <String>{
  'restart',
  'cleanup_then_restart',
  'continue',
};

void _validateIdempotencyBlock(
  Map<dynamic, dynamic> idem,
  String path,
  List<LintFinding> out,
) {
  final inputs = idem['inputs'];
  if (inputs != null && inputs is! Map) {
    out.add(
      LintFinding(LintSeverity.error, path, 'idempotency.inputs must be a map'),
    );
  }

  for (final field in const ['pre_check', 'post_check', 'cleanup']) {
    final value = idem[field];
    if (value == null) continue;
    if (value is! String) {
      out.add(
        LintFinding(
          LintSeverity.error,
          path,
          'idempotency.$field must be a string',
        ),
      );
      continue;
    }
    if (value.trim().isEmpty) {
      out.add(
        LintFinding(
          LintSeverity.error,
          path,
          'idempotency.$field must not be empty',
        ),
      );
    }
  }

  final resume = idem['resume'];
  if (resume != null &&
      (resume is! String || !_resumeStrategies.contains(resume))) {
    out.add(
      LintFinding(
        LintSeverity.error,
        path,
        'idempotency.resume must be one of: '
        '${_resumeStrategies.join(', ')}',
      ),
    );
  }

  if (resume == 'cleanup_then_restart') {
    final cleanup = idem['cleanup'];
    if (cleanup is! String || cleanup.trim().isEmpty) {
      out.add(
        LintFinding(
          LintSeverity.error,
          path,
          'idempotency.cleanup is required for cleanup_then_restart',
        ),
      );
    }
  }
}

void _walkSnapshotPaths(Map<String, dynamic> profile, List<LintFinding> out) {
  final stockOs = profile['stock_os'];
  if (stockOs is! Map) return;
  final snapshotPaths = stockOs['snapshot_paths'];
  if (snapshotPaths is! List) return;
  for (var i = 0; i < snapshotPaths.length; i++) {
    final entry = snapshotPaths[i];
    if (entry is! Map) continue;
    final paths = entry['paths'];
    if (paths is! List) continue;
    for (var j = 0; j < paths.length; j++) {
      final path = paths[j];
      if (path is String && path.startsWith('-')) {
        out.add(
          LintFinding(
            LintSeverity.error,
            'stock_os.snapshot_paths[$i].paths[$j]',
            'snapshot path must not begin with "-"',
          ),
        );
      }
    }
  }
}

void _walkCommandSurfaces(Map<String, dynamic> profile, List<LintFinding> out) {
  _walkGitSources(profile, '', out);

  final flows = profile['flows'];
  if (flows is! Map) return;
  flows.forEach((flowName, flow) {
    if (flow is! Map) return;
    final steps = flow['steps'];
    if (steps is! List) return;
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      if (step is! Map || step['kind'] != 'script') continue;
      final interpreter = step['interpreter'];
      if (interpreter is String && !_isSafeInterpreter(interpreter)) {
        out.add(
          LintFinding(
            LintSeverity.error,
            'flows.$flowName.steps[$i].interpreter',
            'script interpreter must be a single executable name or '
                'absolute path, got "$interpreter"',
          ),
        );
      }
    }
  });
}

void _walkUnsupportedRuntimeFeatures(
  Map<String, dynamic> profile,
  List<LintFinding> out,
) {
  final screens = profile['screens'];
  if (screens is List) {
    for (var i = 0; i < screens.length; i++) {
      final screen = screens[i];
      if (screen is! Map) continue;
      final sourceKind = screen['source_kind'];
      if (sourceKind == null || sourceKind == 'bundled') {
        final sourcePath = screen['source_path'];
        if (sourcePath is! String || sourcePath.trim().isEmpty) {
          out.add(
            LintFinding(
              LintSeverity.error,
              'screens[$i].source_path',
              'bundled screen sources must declare source_path',
            ),
          );
        } else if (!_isSafeProfileAssetPath(sourcePath)) {
          out.add(
            LintFinding(
              LintSeverity.error,
              'screens[$i].source_path',
              'bundled screen source_path must be a profile-local path '
                  'or shared/... path with no traversal',
            ),
          );
        }
        final installScript = screen['install_script'];
        if (installScript is String &&
            installScript.trim().isNotEmpty &&
            !_isSafeProfileAssetPath(installScript)) {
          out.add(
            LintFinding(
              LintSeverity.error,
              'screens[$i].install_script',
              'bundled screen install_script must be a profile-local path '
                  'or shared/... path with no traversal',
            ),
          );
        }
        continue;
      }
      if (sourceKind == 'stock_in_place' || sourceKind == 'hardware_optional') {
        continue;
      }
      out.add(
        LintFinding(
          LintSeverity.error,
          'screens[$i].source_kind',
          'screen source_kind "${sourceKind ?? '<missing>'}" is not '
              'supported by Deckhand yet; supported value: bundled',
        ),
      );
    }
  }

  final flows = profile['flows'];
  if (flows is! Map) return;
  flows.forEach((flowName, flow) {
    if (flow is! Map) return;
    final steps = flow['steps'];
    if (steps is! List) return;
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      if (step is! Map || step['kind'] != 'flash_mcus') continue;
      out.add(
        LintFinding(
          LintSeverity.error,
          'flows.$flowName.steps[$i]',
          'flash_mcus is not supported by Deckhand yet; keep this out '
              'of tagged profiles until the MCU flash transport contract '
              'exists',
        ),
      );
    }
  });
}

void _walkGitSources(Object? node, String path, List<LintFinding> out) {
  if (node is Map<String, dynamic>) {
    if (node['repo'] is String) {
      final repo = node['repo'] as String;
      if (!_isSafeHttpsGitUrl(repo)) {
        out.add(
          LintFinding(
            LintSeverity.error,
            path.isEmpty ? 'repo' : '$path.repo',
            'git repo must be an https:// URL with no credentials, '
            'query, or fragment',
          ),
        );
      }
      final ref = node['ref'];
      if (ref is String && !_isSafeGitRef(ref)) {
        out.add(
          LintFinding(
            LintSeverity.error,
            path.isEmpty ? 'ref' : '$path.ref',
            'git ref must not look like an option or contain traversal',
          ),
        );
      }
    }
    final releaseRepo = node['release_repo'];
    if (releaseRepo is String &&
        !RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(releaseRepo)) {
      out.add(
        LintFinding(
          LintSeverity.error,
          path.isEmpty ? 'release_repo' : '$path.release_repo',
          'release_repo must be "owner/repo" with no URL syntax',
        ),
      );
    }
    final assetPattern = node['asset_pattern'];
    if (assetPattern is String &&
        (assetPattern.isEmpty ||
            assetPattern.contains('/') ||
            assetPattern.contains('\\') ||
            assetPattern == '.' ||
            assetPattern == '..')) {
      out.add(
        LintFinding(
          LintSeverity.error,
          path.isEmpty ? 'asset_pattern' : '$path.asset_pattern',
          'asset_pattern must be a file name glob',
        ),
      );
    }
    node.forEach((key, value) {
      final child = path.isEmpty ? key : '$path.$key';
      _walkGitSources(value, child, out);
    });
  } else if (node is List) {
    for (var i = 0; i < node.length; i++) {
      _walkGitSources(node[i], '$path[$i]', out);
    }
  }
}

bool _isSafeInterpreter(String value) {
  return RegExp(r'^[A-Za-z_][A-Za-z0-9._+-]*$').hasMatch(value) ||
      RegExp(r'^/(?:[A-Za-z0-9._+-]+/)*[A-Za-z0-9._+-]+$').hasMatch(value);
}

bool _isSafeHttpsGitUrl(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment;
}

bool _isSafeGitRef(String value) {
  return value.isNotEmpty &&
      !value.startsWith('-') &&
      !value.startsWith('/') &&
      !value.contains('..') &&
      !value.contains('\\') &&
      RegExp(r'^[A-Za-z0-9._/-]+$').hasMatch(value);
}

bool _isSafeProfileAssetPath(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed.contains('\u0000')) return false;
  if (trimmed.startsWith('/') || trimmed.startsWith('\\')) return false;
  if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(trimmed)) return false;
  if (trimmed.startsWith('~')) return false;

  final normalized = trimmed.replaceAll('\\', '/');
  final relative = normalized.startsWith('./')
      ? normalized.substring(2)
      : normalized;
  if (relative.isEmpty) return false;
  return !relative.split('/').any((part) => part == '..');
}

void _walkUrlsAndHashes(Object? node, String path, List<LintFinding> out) {
  if (node is Map<String, dynamic>) {
    final isReleaseAsset =
        node['release_repo'] is String || node['asset_pattern'] is String;
    final isOsImage = _isOsImageDownloadNode(path, node);
    if (isReleaseAsset && node['sha256'] is! String) {
      out.add(
        LintFinding(
          LintSeverity.error,
          path.isEmpty ? 'sha256' : '$path.sha256',
          'release asset components must declare sha256',
        ),
      );
    }
    if (isOsImage && node['sha256'] is! String) {
      out.add(
        LintFinding(
          LintSeverity.error,
          path.isEmpty ? 'sha256' : '$path.sha256',
          'OS image downloads must declare sha256',
        ),
      );
    }

    // Only flag `url` as needing https:// when this same node ALSO carries
    // a `sha256` — i.e. when it's a download we're going to integrity-check
    // (fresh_install_options, firmware-blob fetches, etc.). Verifier URLs
    // that hit Moonraker / Klippy on the printer's LAN are http:// by
    // design (Moonraker doesn't ship TLS, the trusted_clients list bounds
    // the access scope, the endpoint is templated against {{host}}).
    final hasSha = node['sha256'] is String;
    node.forEach((key, value) {
      final child = path.isEmpty ? key : '$path.$key';
      if (key == 'url' && value is String && (hasSha || isOsImage)) {
        if (!value.startsWith('https://')) {
          out.add(
            LintFinding(
              LintSeverity.error,
              child,
              'url must be https:// (this node has a sha256 — '
              'it\'s a download), got "$value"',
            ),
          );
        }
      }
      if (key == 'sha256' && value is String) {
        if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
          out.add(
            LintFinding(
              LintSeverity.error,
              child,
              'sha256 must be 64 hex chars, got "${value.length} chars"',
            ),
          );
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

bool _isOsImageDownloadNode(String path, Map<String, dynamic> node) {
  if (node['url'] is! String) return false;
  final normalized = path.toLowerCase();
  return normalized.contains('fresh_install_options[') ||
      normalized.contains('fresh_flash.images[');
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

int _countProfiles(Directory root) {
  final printers = Directory(p.join(root.path, 'printers'));
  if (!printers.existsSync()) return 0;
  return printers
      .listSync()
      .whereType<Directory>()
      .where((d) => File(p.join(d.path, 'profile.yaml')).existsSync())
      .length;
}

/// Reads every `printers/<id>/profile.yaml` and emits the canonical
/// `registry.yaml` content. The registry is a pure derived view of the
/// profile.yamls — `--regenerate-registry` rewrites it; the default
/// lint pass diffs the on-disk file against this output and fails on
/// drift. The header comment is preserved verbatim across regenerations
/// so the file remains self-documenting.
Future<String> _generateRegistry(Directory root) async {
  final printersDir = Directory(p.join(root.path, 'printers'));
  final entries = <Map<String, Object?>>[];
  if (printersDir.existsSync()) {
    final dirs =
        printersDir
            .listSync()
            .whereType<Directory>()
            .where((d) => File(p.join(d.path, 'profile.yaml')).existsSync())
            .toList()
          ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    for (final dir in dirs) {
      final folder = p.basename(dir.path);
      final raw = await File(p.join(dir.path, 'profile.yaml')).readAsString();
      final parsed = _toPlain(loadYaml(raw));
      if (parsed is! Map) continue;
      final id = parsed['profile_id'] as String? ?? folder;
      // Preserve `latest_tag` from the existing registry — it's set by
      // release CI and isn't sourced from profile.yaml. A fresh-from-
      // scratch generation would null it; we don't want to clobber a
      // tag set by the release pipeline.
      final existingTag = await _readExistingLatestTag(root, id);
      entries.add(<String, Object?>{
        'id': id,
        'display_name': parsed['display_name'],
        'manufacturer': parsed['manufacturer'],
        'model': parsed['model'],
        'status': parsed['status'],
        'directory': 'printers/$folder',
        'latest_tag': existingTag,
        // Spec-card highlights — surfaced in the printer-picker. SBC,
        // kinematics, and MCU are derived from `hardware:`; extras is
        // designer-authored via `picker_extras`. All four nullable so
        // a profile that hasn't filled `hardware:` yet still lints.
        'sbc': _deriveSbc(parsed),
        'kinematics': _deriveKinematics(parsed),
        'mcu': _deriveMcu(parsed),
        'extras': parsed['picker_extras'] as String?,
      });
    }
  }

  final buf = StringBuffer();
  buf.writeln('# Deckhand Builds — profile registry');
  buf.writeln('#');
  buf.writeln('# GENERATED. Do not hand-edit. Edit the per-printer');
  buf.writeln('# `printers/<id>/profile.yaml` and regenerate via:');
  buf.writeln('#');
  buf.writeln('#   dart run deckhand_profile_lint --root . \\');
  buf.writeln('#                                  --regenerate-registry');
  buf.writeln('#');
  buf.writeln('# CI runs the lint without the flag and fails the build');
  buf.writeln('# if any registry field has drifted from the profile.');
  buf.writeln('# `latest_tag` is the one field the release pipeline');
  buf.writeln('# sets independently — the generator preserves whatever');
  buf.writeln('# value is already on disk for that field.');
  buf.writeln();
  buf.writeln('schema_version: 1');
  buf.writeln();
  buf.writeln('profiles:');
  for (var i = 0; i < entries.length; i++) {
    final e = entries[i];
    if (i > 0) buf.writeln();
    buf.writeln('  - id: ${_yamlScalar(e['id'])}');
    buf.writeln('    display_name: ${_yamlScalar(e['display_name'])}');
    buf.writeln('    manufacturer: ${_yamlScalar(e['manufacturer'])}');
    buf.writeln('    model: ${_yamlScalar(e['model'])}');
    buf.writeln('    status: ${_yamlScalar(e['status'])}');
    buf.writeln('    directory: ${_yamlScalar(e['directory'])}');
    buf.writeln('    latest_tag: ${_yamlNullable(e['latest_tag'])}');
    // Spec-card highlights are only emitted when populated. Omitting
    // null entries keeps the registry diff small for profiles that
    // don't have a `hardware:` block filled out yet, and keeps the
    // generator output stable as new fields land.
    if (e['sbc'] != null) {
      buf.writeln('    sbc: ${_yamlScalar(e['sbc'])}');
    }
    if (e['kinematics'] != null) {
      buf.writeln('    kinematics: ${_yamlScalar(e['kinematics'])}');
    }
    if (e['mcu'] != null) {
      buf.writeln('    mcu: ${_yamlScalar(e['mcu'])}');
    }
    if (e['extras'] != null) {
      buf.writeln('    extras: ${_yamlScalar(e['extras'])}');
    }
  }
  return buf.toString();
}

/// Cleaned-up SoC label from `hardware.sbc.soc`. Strips the vendor
/// prefix where it makes the result redundant (rk3328, h616 already
/// say "Rockchip" / "Allwinner" implicitly to anyone shopping for
/// SBCs) and uppercases the chip name. Returns null when the field
/// is missing — the picker tolerates that and renders "—".
String? _deriveSbc(Map<dynamic, dynamic> parsed) {
  final hw = parsed['hardware'];
  if (hw is! Map) return null;
  final sbc = hw['sbc'];
  if (sbc is! Map) return null;
  final soc = sbc['soc'];
  if (soc is! String || soc.isEmpty) return null;
  // "rockchip-rk3328" → "RK3328", "allwinner-h616" → "Allwinner H616".
  // Vendors with their own brand recognition (Rockchip) don't need
  // restating; the chip ID alone is the discriminating part. For
  // less recognizable chip IDs, keep the vendor as well.
  final parts = soc.split('-');
  if (parts.length == 1) return parts[0].toUpperCase();
  final vendor = parts.first;
  final chip = parts.sublist(1).join(' ').toUpperCase();
  if (vendor == 'rockchip') return chip;
  return '${_titleCase(vendor)} $chip';
}

/// Pretty-cased kinematics label from `hardware.kinematics`. The
/// registry has used flat lowercase tokens since schema_version 1
/// ("corexy", "cartesian", "delta"); the picker wants display form.
String? _deriveKinematics(Map<dynamic, dynamic> parsed) {
  final hw = parsed['hardware'];
  if (hw is! Map) return null;
  final kin = hw['kinematics'];
  if (kin is! String || kin.isEmpty) return null;
  switch (kin) {
    case 'corexy':
      return 'CoreXY';
    case 'corexz':
      return 'CoreXZ';
    case 'cartesian':
      return 'Cartesian';
    case 'delta':
      return 'Delta';
    case 'scara':
      return 'SCARA';
    default:
      return _titleCase(kin);
  }
}

/// Main MCU label from the top-level `mcus[0].chip`. Strips the
/// trailing package suffix ("xx", "xe") that's noise for the
/// picker's 4-cell summary — "stm32f407xx" reads as "STM32F407" —
/// and uppercases. Returns null when the block is absent.
///
/// `mcus:` is a top-level profile.yaml key (not nested under
/// `hardware:`); the firmware-build pipeline reads it directly
/// for klipper menuconfig overrides, so it predates any picker
/// surface and shouldn't be moved.
String? _deriveMcu(Map<dynamic, dynamic> parsed) {
  final mcus = parsed['mcus'];
  if (mcus is! List || mcus.isEmpty) return null;
  final main = mcus.firstWhere(
    (e) => e is Map && e['id'] == 'main',
    orElse: () => mcus.first,
  );
  if (main is! Map) return null;
  final chip = main['chip'];
  if (chip is! String || chip.isEmpty) return null;
  // STM32 family chips end in a 2-letter package code (xx, xe, xb,
  // re, etc.). Strip ONLY the trailing alpha run so digits + the
  // family identifier ("STM32F407") survive. Chips with no trailing
  // letters (rp2040, gd32f303) round-trip unchanged through the
  // same replace.
  final stripped = chip.replaceFirst(RegExp(r'[a-z]+$'), '');
  return stripped.toUpperCase();
}

String _titleCase(String s) {
  if (s.isEmpty) return s;
  return s[0].toUpperCase() + s.substring(1);
}

Future<Object?> _readExistingLatestTag(Directory root, String id) async {
  final f = File(p.join(root.path, 'registry.yaml'));
  if (!f.existsSync()) return null;
  final doc = loadYaml(await f.readAsString());
  if (doc is! Map || doc['profiles'] is! List) return null;
  for (final entry in doc['profiles'] as List) {
    if (entry is Map && entry['id'] == id) {
      return entry['latest_tag'];
    }
  }
  return null;
}

String _yamlScalar(Object? value) {
  if (value == null) return 'null';
  final s = value.toString();
  // YAML treats unquoted scalars with whitespace as multi-token, and
  // an empty unquoted value parses as null (not the empty string), so
  // empty strings need quoting too. Fields like "SV08 Max" need
  // quoting because of the space; numbers and single-word identifiers
  // round-trip cleanly without quotes.
  if (s.isEmpty ||
      s.contains(' ') ||
      s.contains(':') ||
      s.contains('#') ||
      s.contains('"') ||
      s.contains("'")) {
    final escaped = s.replaceAll('"', r'\"');
    return '"$escaped"';
  }
  return s;
}

String _yamlNullable(Object? value) {
  if (value == null) return 'null';
  return _yamlScalar(value);
}
