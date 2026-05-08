import 'dart:io';

import 'package:deckhand_profile_lint/deckhand_profile_lint.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('deckhand-profile-lint-');
    _writeSchema(tmp);
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('accepts a minimal valid profile', () async {
    _writeRegistry(tmp, ['good-printer']);
    _writeProfile(tmp, 'good-printer', _minimalValidProfile('good-printer'));
    final report = await runProfileLint(['--root', tmp.path]);
    expect(
      report.hasErrors,
      isFalse,
      reason: report.results
          .expand((r) => r.findings.map((f) => '${r.file}: ${f.message}'))
          .join('\n'),
    );
  });

  test('flags http:// urls as an error', () async {
    _writeRegistry(tmp, ['bad-url']);
    final profile =
        '${_minimalValidProfile('bad-url')}'
        '\nflows:\n  fresh_flash:\n    enabled: true\n    images:\n      - id: test\n        display_name: Test\n        url: "http://insecure.example/img.xz"\n        sha256: "${"a" * 64}"\n';
    _writeProfile(tmp, 'bad-url', profile);
    final report = await runProfileLint(['--root', tmp.path]);
    expect(report.hasErrors, isTrue);
  });

  test('flags malformed sha256', () async {
    _writeRegistry(tmp, ['bad-hash']);
    final profile =
        '${_minimalValidProfile('bad-hash')}'
        '\nflows:\n  fresh_flash:\n    images:\n      - id: test\n        display_name: Test\n        url: "https://example/img.xz"\n        sha256: "not-a-hash"\n';
    _writeProfile(tmp, 'bad-hash', profile);
    final report = await runProfileLint(['--root', tmp.path]);
    expect(report.hasErrors, isTrue);
  });

  test('flags release assets missing sha256', () async {
    _writeRegistry(tmp, ['release-no-hash']);
    final profile =
        '${_minimalValidProfile('release-no-hash')}'
        '\nstack:\n  webui:\n    release_repo: fluidd-core/fluidd\n'
        '    asset_pattern: fluidd.zip\n'
        '    install_path: ~/fluidd\n';
    _writeProfile(tmp, 'release-no-hash', profile);
    final report = await runProfileLint(['--root', tmp.path]);
    expect(report.hasErrors, isTrue);
    final messages = report.results
        .expand((r) => r.findings.map((f) => f.message))
        .join('\n');
    expect(messages, contains('release asset'));
  });

  test('flags OS image downloads missing sha256', () async {
    _writeRegistry(tmp, ['os-no-hash']);
    final profile =
        '${_minimalValidProfile('os-no-hash')}'
        '\nos:\n  fresh_install_options:\n'
        '    - id: debian\n'
        '      display_name: Debian\n'
        '      url: "https://example.com/debian.img"\n';
    _writeProfile(tmp, 'os-no-hash', profile);
    final report = await runProfileLint(['--root', tmp.path]);
    expect(report.hasErrors, isTrue);
    final messages = report.results
        .expand((r) => r.findings.map((f) => f.message))
        .join('\n');
    expect(messages, contains('OS image'));
  });

  test('flags snapshot paths that look like tar options', () async {
    _writeRegistry(tmp, ['tar-option-path']);
    final profile =
        '${_minimalValidProfile('tar-option-path')}'
        '\nstock_os:\n  snapshot_paths:\n'
        '    - id: bad\n'
        '      display_name: Bad\n'
        '      paths:\n'
        '        - "--checkpoint-action=exec=touch /tmp/pwned"\n';
    _writeProfile(tmp, 'tar-option-path', profile);
    final report = await runProfileLint(['--root', tmp.path]);
    expect(report.hasErrors, isTrue);
    final messages = report.results
        .expand((r) => r.findings.map((f) => f.message))
        .join('\n');
    expect(messages, contains('snapshot path'));
  });

  test('flags unsafe script interpreters', () async {
    _writeRegistry(tmp, ['bad-interpreter']);
    final profile =
        '${_minimalValidProfile('bad-interpreter')}'
        '\nflows:\n  stock_keep:\n    enabled: true\n    steps:\n'
        '      - id: injected\n'
        '        kind: script\n'
        '        path: ./scripts/noop.sh\n'
        '        interpreter: "bash; touch /tmp/pwned"\n';
    _writeProfile(tmp, 'bad-interpreter', profile);
    final report = await runProfileLint(['--root', tmp.path]);
    expect(report.hasErrors, isTrue);
    final messages = report.results
        .expand((r) => r.findings.map((f) => f.message))
        .join('\n');
    expect(messages, contains('script interpreter'));
  });

  test('flags unsafe git repo and ref values', () async {
    _writeRegistry(tmp, ['bad-git']);
    final profile =
        '${_minimalValidProfile('bad-git')}'
        '\nfirmware:\n  choices:\n'
        '    - id: fw\n'
        '      display_name: Firmware\n'
        '      repo: "https://token@example.com/repo.git"\n'
        '      ref: "--upload-pack=touch-pwned"\n';
    _writeProfile(tmp, 'bad-git', profile);
    final report = await runProfileLint(['--root', tmp.path]);
    expect(report.hasErrors, isTrue);
    final messages = report.results
        .expand((r) => r.findings.map((f) => f.message))
        .join('\n');
    expect(messages, contains('git repo'));
    expect(messages, contains('git ref'));
  });

  test('flags release asset patterns with path separators', () async {
    _writeRegistry(tmp, ['bad-asset-pattern']);
    final profile =
        '${_minimalValidProfile('bad-asset-pattern')}'
        '\nstack:\n  webui:\n    release_repo: fluidd-core/fluidd\n'
        '    asset_pattern: "../fluidd.zip"\n'
        '    sha256: "${"a" * 64}"\n'
        '    install_path: ~/fluidd\n';
    _writeProfile(tmp, 'bad-asset-pattern', profile);
    final report = await runProfileLint(['--root', tmp.path]);
    expect(report.hasErrors, isTrue);
    final messages = report.results
        .expand((r) => r.findings.map((f) => f.message))
        .join('\n');
    expect(messages, contains('asset_pattern'));
  });

  group('unsupported runtime features', () {
    test(
      'allows bundled screen sources and the default bundled source',
      () async {
        _writeRegistry(tmp, ['bundled-screens']);
        final profile =
            '${_minimalValidProfile('bundled-screens')}'
            '\nscreens:\n'
            '  - id: default_lcd\n'
            '    source_path: ./screens/default_lcd\n'
            '  - id: bundled_lcd\n'
            '    source_kind: bundled\n'
            '    source_path: ./screens/bundled_lcd\n';
        _writeProfile(tmp, 'bundled-screens', profile);

        final report = await runProfileLint(['--root', tmp.path]);

        expect(report.hasErrors, isFalse);
      },
    );

    test('flags screen restore-from-backup sources', () async {
      _writeRegistry(tmp, ['screen-restore']);
      final profile =
          '${_minimalValidProfile('screen-restore')}'
          '\nscreens:\n'
          '  - id: lcd\n'
          '    source_kind: restore_from_backup\n'
          '\nflows:\n'
          '  stock_keep:\n'
          '    enabled: true\n'
          '    steps:\n'
          '      - id: screen\n'
          '        kind: install_screen\n'
          '        safe_to_rerun: true\n';
      _writeProfile(tmp, 'screen-restore', profile);
      final report = await runProfileLint(['--root', tmp.path]);

      expect(report.hasErrors, isTrue);
      final messages = report.results
          .expand((r) => r.findings.map((f) => f.message))
          .join('\n');
      expect(messages, contains('restore_from_backup'));
    });

    test('flags bundled screen sources without source_path', () async {
      _writeRegistry(tmp, ['screen-missing-source']);
      final profile =
          '${_minimalValidProfile('screen-missing-source')}'
          '\nscreens:\n'
          '  - id: lcd\n'
          '    source_kind: bundled\n';
      _writeProfile(tmp, 'screen-missing-source', profile);
      final report = await runProfileLint(['--root', tmp.path]);

      expect(report.hasErrors, isTrue);
      final messages = report.results
          .expand((r) => r.findings.map((f) => f.message))
          .join('\n');
      expect(messages, contains('source_path'));
    });

    test('flags bundled screen sources outside the profile checkout', () async {
      _writeRegistry(tmp, ['screen-unsafe-source']);
      final profile =
          '${_minimalValidProfile('screen-unsafe-source')}'
          '\nscreens:\n'
          '  - id: traversal\n'
          '    source_path: ../outside\n'
          '  - id: absolute\n'
          '    source_kind: bundled\n'
          '    source_path: C:\\\\tmp\\\\lcd\n'
          '  - id: script\n'
          '    source_path: ./screens/lcd\n'
          '    install_script: ../install.sh\n';
      _writeProfile(tmp, 'screen-unsafe-source', profile);
      final report = await runProfileLint(['--root', tmp.path]);

      expect(report.hasErrors, isTrue);
      final messages = report.results
          .expand((r) => r.findings.map((f) => f.message))
          .join('\n');
      expect(messages, contains('source_path'));
      expect(messages, contains('install_script'));
      expect(messages, contains('profile-local path'));
    });

    test('flags flash_mcus steps with explicit targets', () async {
      _writeRegistry(tmp, ['mcu-flash']);
      final profile =
          '${_minimalValidProfile('mcu-flash')}'
          '\nflows:\n'
          '  stock_keep:\n'
          '    enabled: true\n'
          '    steps:\n'
          '      - id: flash_mcus\n'
          '        kind: flash_mcus\n'
          '        safe_to_rerun: true\n'
          '        which: [main]\n'
          '\nmcus:\n'
          '  - id: main\n'
          '    chip: stm32f407xx\n';
      _writeProfile(tmp, 'mcu-flash', profile);
      final report = await runProfileLint(['--root', tmp.path]);

      expect(report.hasErrors, isTrue);
      final messages = report.results
          .expand((r) => r.findings.map((f) => f.message))
          .join('\n');
      expect(messages, contains('flash_mcus'));
    });

    test('flags flash_mcus steps without explicit targets', () async {
      _writeRegistry(tmp, ['mcu-flash-empty']);
      final profile =
          '${_minimalValidProfile('mcu-flash-empty')}'
          '\nflows:\n'
          '  stock_keep:\n'
          '    enabled: true\n'
          '    steps:\n'
          '      - id: flash_mcus\n'
          '        kind: flash_mcus\n'
          '        safe_to_rerun: true\n';
      _writeProfile(tmp, 'mcu-flash-empty', profile);
      final report = await runProfileLint(['--root', tmp.path]);

      expect(report.hasErrors, isTrue);
      final messages = report.results
          .expand((r) => r.findings.map((f) => f.message))
          .join('\n');
      expect(messages, contains('flash_mcus'));
    });
  });

  test('flags folder/profile_id mismatch', () async {
    _writeRegistry(tmp, ['right-id']);
    _writeProfile(tmp, 'wrong-folder', _minimalValidProfile('right-id'));
    final report = await runProfileLint(['--root', tmp.path]);
    expect(report.hasErrors, isTrue);
  });

  test('flags profile missing from registry', () async {
    _writeRegistry(tmp, ['listed']);
    _writeProfile(tmp, 'unlisted', _minimalValidProfile('unlisted'));
    final report = await runProfileLint(['--root', tmp.path]);
    expect(report.hasErrors, isTrue);
  });

  test('status=stub is a warning that --strict escalates to error', () async {
    // Mirror the stub status in the registry too — the drift check
    // would otherwise fire and contaminate the assertion.
    _writeRegistryWithStatus(tmp, 'still-stub', 'stub');
    final stub = _minimalValidProfile(
      'still-stub',
    ).replaceAll('status: stable', 'status: stub');
    _writeProfile(tmp, 'still-stub', stub);
    final lenient = await runProfileLint(['--root', tmp.path]);
    expect(lenient.hasErrors, isFalse);
    final strict = await runProfileLint(['--root', tmp.path, '--strict']);
    expect(strict.hasErrors, isTrue);
  });

  group('registry-drift detection', () {
    test('flags status drift between registry and profile', () async {
      // Reproduces the production bug: registry says alpha, profile
      // says beta. Picker reads from registry and shows stale state.
      _writeRegistryWithStatus(tmp, 'arco', 'alpha');
      final profile = _minimalValidProfile(
        'arco',
      ).replaceAll('status: stable', 'status: beta');
      _writeProfile(tmp, 'arco', profile);
      final report = await runProfileLint(['--root', tmp.path]);
      expect(
        report.hasErrors,
        isTrue,
        reason: 'lint should flag status drift between registry and profile',
      );
      final messages = report.results
          .expand((r) => r.findings.map((f) => f.message))
          .toList();
      expect(
        messages.any((m) => m.contains('alpha') && m.contains('beta')),
        isTrue,
        reason:
            'finding should call out both the registry and profile values, '
            'got: ${messages.join(' | ')}',
      );
    });

    test('passes when registry mirrors profile metadata exactly', () async {
      _writeRegistry(tmp, ['matched']);
      _writeProfile(tmp, 'matched', _minimalValidProfile('matched'));
      final report = await runProfileLint(['--root', tmp.path]);
      expect(report.hasErrors, isFalse);
    });

    test('--regenerate-registry rewrites registry from profile', () async {
      _writeRegistryWithStatus(tmp, 'arco', 'alpha');
      final profile = _minimalValidProfile(
        'arco',
      ).replaceAll('status: stable', 'status: beta');
      _writeProfile(tmp, 'arco', profile);

      final regen = await runProfileLint([
        '--root',
        tmp.path,
        '--regenerate-registry',
      ]);
      expect(regen.hasErrors, isFalse);
      final regenContent = File(
        p.join(tmp.path, 'registry.yaml'),
      ).readAsStringSync();
      expect(
        regenContent,
        contains('status: beta'),
        reason: 'regenerated registry should reflect the profile',
      );
      expect(
        regenContent,
        isNot(contains('status: alpha')),
        reason: 'regenerated registry should drop the stale alpha',
      );

      // Subsequent lint pass should be clean.
      final lint = await runProfileLint(['--root', tmp.path]);
      expect(lint.hasErrors, isFalse);
    });
  });

  group('idempotency contract', () {
    test('warns on a step missing the idempotency block', () async {
      _writeRegistry(tmp, ['missing-idem']);
      final profile =
          '${_minimalValidProfile('missing-idem')}'
          '\nflows:\n  stock_keep:\n    enabled: true\n    steps:\n'
          '      - id: install_klipper\n'
          '        kind: install_firmware\n';
      _writeProfile(tmp, 'missing-idem', profile);
      final report = await runProfileLint(['--root', tmp.path]);
      // Lenient: warning only.
      expect(report.hasErrors, isFalse);
      final allMessages = report.results
          .expand((r) => r.findings.map((f) => f.message))
          .join('\n');
      expect(allMessages, contains('idempotency'));
    });

    test(
      '--strict turns the missing-idempotency warning into an error',
      () async {
        _writeRegistry(tmp, ['strict-idem']);
        final profile =
            '${_minimalValidProfile('strict-idem')}'
            '\nflows:\n  stock_keep:\n    enabled: true\n    steps:\n'
            '      - id: install_klipper\n'
            '        kind: install_firmware\n';
        _writeProfile(tmp, 'strict-idem', profile);
        final strict = await runProfileLint(['--root', tmp.path, '--strict']);
        expect(strict.hasErrors, isTrue);
      },
    );

    test('safe_to_rerun: true silences the warning', () async {
      _writeRegistry(tmp, ['safe-rerun']);
      final profile =
          '${_minimalValidProfile('safe-rerun')}'
          '\nflows:\n  stock_keep:\n    enabled: true\n    steps:\n'
          '      - id: install_klipper\n'
          '        kind: install_firmware\n'
          '        safe_to_rerun: true\n';
      _writeProfile(tmp, 'safe-rerun', profile);
      final strict = await runProfileLint(['--root', tmp.path, '--strict']);
      expect(strict.hasErrors, isFalse);
    });

    test(
      'built-in idempotent kinds (snapshot_archive) need no block',
      () async {
        _writeRegistry(tmp, ['builtin-idem']);
        final profile =
            '${_minimalValidProfile('builtin-idem')}'
            '\nflows:\n  stock_keep:\n    enabled: true\n    steps:\n'
            '      - id: snap\n'
            '        kind: snapshot_archive\n';
        _writeProfile(tmp, 'builtin-idem', profile);
        final strict = await runProfileLint(['--root', tmp.path, '--strict']);
        expect(strict.hasErrors, isFalse);
      },
    );

    test('declared idempotency block satisfies the rule', () async {
      _writeRegistry(tmp, ['declared-idem']);
      final profile =
          '${_minimalValidProfile('declared-idem')}'
          '\nflows:\n  stock_keep:\n    enabled: true\n    steps:\n'
          '      - id: install_klipper\n'
          '        kind: install_firmware\n'
          '        idempotency:\n'
          '          pre_check: "test -d ~/klipper"\n'
          '          resume: cleanup_then_restart\n'
          '          cleanup: "rm -rf ~/klipper.partial"\n';
      _writeProfile(tmp, 'declared-idem', profile);
      final strict = await runProfileLint(['--root', tmp.path, '--strict']);
      expect(strict.hasErrors, isFalse);
    });

    test('rejects malformed idempotency block fields', () async {
      _writeRegistry(tmp, ['bad-idem']);
      final profile =
          '${_minimalValidProfile('bad-idem')}'
          '\nflows:\n  stock_keep:\n    enabled: true\n    steps:\n'
          '      - id: install_klipper\n'
          '        kind: install_firmware\n'
          '        idempotency:\n'
          '          inputs: []\n'
          '          pre_check: []\n'
          '          post_check: ""\n'
          '          resume: teleport\n';
      _writeProfile(tmp, 'bad-idem', profile);
      final report = await runProfileLint(['--root', tmp.path]);
      expect(report.hasErrors, isTrue);
      final messages = report.results
          .expand((r) => r.findings.map((f) => f.message))
          .join('\n');
      expect(messages, contains('idempotency.inputs must be a map'));
      expect(messages, contains('idempotency.pre_check must be a string'));
      expect(messages, contains('idempotency.post_check must not be empty'));
      expect(messages, contains('idempotency.resume must be one of'));
    });

    test('cleanup_then_restart requires a cleanup command', () async {
      _writeRegistry(tmp, ['missing-cleanup']);
      final profile =
          '${_minimalValidProfile('missing-cleanup')}'
          '\nflows:\n  stock_keep:\n    enabled: true\n    steps:\n'
          '      - id: install_klipper\n'
          '        kind: install_firmware\n'
          '        idempotency:\n'
          '          pre_check: "test -d ~/klipper"\n'
          '          resume: cleanup_then_restart\n';
      _writeProfile(tmp, 'missing-cleanup', profile);
      final report = await runProfileLint(['--root', tmp.path]);
      expect(report.hasErrors, isTrue);
      final messages = report.results
          .expand((r) => r.findings.map((f) => f.message))
          .join('\n');
      expect(
        messages,
        contains('idempotency.cleanup is required for cleanup_then_restart'),
      );
    });
  });
}

void _writeSchema(Directory root) {
  final schemaDir = Directory(p.join(root.path, 'schema'))
    ..createSync(recursive: true);
  // Minimal subset of the real schema — enough for these tests.
  File(p.join(schemaDir.path, 'profile.schema.json')).writeAsStringSync(r'''
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "required": ["schema_version", "profile_id", "profile_version", "display_name", "status"],
  "properties": {
    "schema_version": {"type": "integer", "const": 1},
    "profile_id": {"type": "string", "pattern": "^[a-z0-9-]+$"},
    "profile_version": {"type": "string", "pattern": "^\\d+\\.\\d+\\.\\d+$"},
    "display_name": {"type": "string", "minLength": 1},
    "status": {"type": "string", "enum": ["stub", "alpha", "beta", "stable", "deprecated"]}
  }
}
''');
}

void _writeRegistry(Directory root, List<String> profileIds) {
  // The real registry mirrors a handful of fields from each
  // profile.yaml so the picker can render printer cards without
  // fetching every full profile. The minimal-valid-profile helper
  // sets display_name / status, so we reflect those here too — the
  // drift check would otherwise fire on every test that uses these
  // helpers naively.
  final entries = profileIds
      .map(
        (id) =>
            '  - id: $id\n'
            '    display_name: "$id"\n'
            '    manufacturer: ""\n'
            '    model: ""\n'
            '    status: stable\n'
            '    directory: printers/$id\n'
            '    latest_tag: null',
      )
      .join('\n');
  File(
    p.join(root.path, 'registry.yaml'),
  ).writeAsStringSync('schema_version: 1\nprofiles:\n$entries\n');
}

/// Variant for drift tests: write a registry whose mirrored fields
/// disagree with what the profile.yaml will say. Lets a test prove
/// the drift detector catches the exact `status: alpha`/`status: beta`
/// case that bit Arco in production.
void _writeRegistryWithStatus(Directory root, String id, String status) {
  File(p.join(root.path, 'registry.yaml')).writeAsStringSync(
    'schema_version: 1\n'
    'profiles:\n'
    '  - id: $id\n'
    '    display_name: "$id"\n'
    '    manufacturer: ""\n'
    '    model: ""\n'
    '    status: $status\n'
    '    directory: printers/$id\n'
    '    latest_tag: null\n',
  );
}

void _writeProfile(Directory root, String folder, String contents) {
  final dir = Directory(p.join(root.path, 'printers', folder))
    ..createSync(recursive: true);
  File(p.join(dir.path, 'profile.yaml')).writeAsStringSync(contents);
}

String _minimalValidProfile(String id) =>
    '''
schema_version: 1
profile_id: $id
profile_version: 0.0.1
display_name: "$id"
manufacturer: ""
model: ""
status: stable
''';
