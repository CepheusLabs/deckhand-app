import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_flash/deckhand_flash.dart';
import 'package:deckhand_profiles/src/sidecar_profile_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Tests for [parseProfileYaml], the pure-string seam for
/// [SidecarProfileService.load]. We exercise it directly instead of
/// the service so tests don't depend on File I/O or a sidecar process.
void main() {
  const validProfile = '''
schema_version: 1
profile_id: test-printer
profile_version: 0.1.0
display_name: Test Printer
status: alpha
manufacturer: Acme
model: Robo
hardware:
  architecture: aarch64
os:
  fresh_install_options:
    - id: debian
      display_name: Debian 12
      url: https://example.com/img
ssh:
  default_credentials:
    - user: mks
      password: makerbase
firmware:
  choices:
    - id: kalico
      display_name: Kalico
      repo: https://github.com/KalicoCrew/kalico
      ref: main
  default_choice: kalico
flows:
  stock_keep:
    enabled: true
    steps: []
''';

  group('parseProfileYaml happy path', () {
    test('parses a valid minimal profile into the model', () {
      final profile = parseProfileYaml(validProfile);
      expect(profile.id, 'test-printer');
      expect(profile.version, '0.1.0');
      expect(profile.displayName, 'Test Printer');
      expect(profile.status, ProfileStatus.alpha);
      expect(profile.manufacturer, 'Acme');
      expect(profile.model, 'Robo');
      expect(profile.hardware.architecture, 'aarch64');
      expect(profile.os.freshInstallOptions.single.id, 'debian');
      expect(profile.firmware.defaultChoice, 'kalico');
      expect(profile.flows.stockKeep?.enabled, isTrue);
    });

    test('preserves unknown future keys (forward compatibility)', () {
      // A profile from a newer deckhand-profiles release may carry
      // fields this app version doesn't model yet. They must round-
      // trip through `raw` so persisted state, logs, and bug reports
      // don't silently drop the data.
      const withUnknown = '''
schema_version: 99
profile_id: future-printer
profile_version: 9.9.9
display_name: Future Printer
status: alpha
brand_new_key: some-value
nested_future_block:
  color: orange
  thermal_runaway_grace_seconds: 5
''';
      final profile = parseProfileYaml(withUnknown);
      expect(profile.id, 'future-printer');
      expect(profile.raw['brand_new_key'], 'some-value');
      expect(profile.raw['nested_future_block'], isA<Map<String, dynamic>>());
      expect(
        (profile.raw['nested_future_block'] as Map<String, dynamic>)['color'],
        'orange',
      );
    });

    test('status: stub parses to ProfileStatus.stub so the wizard can '
        'refuse to use it', () {
      const stubProfile = '''
schema_version: 1
profile_id: work-in-progress
profile_version: 0.0.1
display_name: WIP
status: stub
''';
      final profile = parseProfileYaml(stubProfile);
      expect(
        profile.status,
        ProfileStatus.stub,
        reason: 'status=stub must survive the parse round-trip',
      );
    });
  });

  group(
    'parseProfileYaml rejects malformed profiles with a clean exception',
    () {
      test('missing schema_version throws ProfileFormatException '
          '(not a cast/null error)', () {
        const noSchema = '''
profile_id: test
profile_version: 0.1.0
display_name: Test
status: alpha
''';
        expect(
          () => parseProfileYaml(noSchema),
          throwsA(
            isA<ProfileFormatException>().having(
              (e) => e.message,
              'message',
              contains('schema_version'),
            ),
          ),
        );
      });

      test('missing profile_id throws ProfileFormatException', () {
        const noId = '''
schema_version: 1
profile_version: 0.1.0
display_name: Test
status: alpha
''';
        expect(
          () => parseProfileYaml(noId),
          throwsA(
            isA<ProfileFormatException>().having(
              (e) => e.message,
              'message',
              contains('profile_id'),
            ),
          ),
        );
      });

      test('empty profile_id throws ProfileFormatException', () {
        const emptyId = '''
schema_version: 1
profile_id: ""
profile_version: 0.1.0
display_name: Test
status: alpha
''';
        expect(
          () => parseProfileYaml(emptyId),
          throwsA(isA<ProfileFormatException>()),
        );
      });

      test('non-mapping root throws ProfileFormatException', () {
        // A YAML list at the root (a common copy-paste mistake when
        // authors paste fragment content) must fail cleanly.
        const listRoot = '''
- one
- two
- three
''';
        expect(
          () => parseProfileYaml(listRoot),
          throwsA(isA<ProfileFormatException>()),
        );
      });

      test('ProfileFormatException.toString includes the message', () {
        const e = ProfileFormatException('missing field `foo`');
        expect(e.toString(), contains('missing field `foo`'));
      });
    },
  );

  group('SidecarProfileService.ensureCached path policy', () {
    test('rejects traversal refs before touching cache or sidecar', () async {
      final tmp = await Directory.systemTemp.createTemp(
        'deckhand-profile-service-',
      );
      addTearDown(() async => tmp.delete(recursive: true));
      final sidecar = _FakeSidecar();
      final svc = SidecarProfileService(
        sidecar: sidecar,
        paths: DeckhandPaths(
          cacheDir: p.join(tmp.path, 'cache'),
          stateDir: p.join(tmp.path, 'state'),
          logsDir: p.join(tmp.path, 'logs'),
          settingsFile: p.join(tmp.path, 'settings.json'),
        ),
        security: _AllowAllSecurity(),
      );

      await expectLater(
        svc.ensureCached(profileId: 'test-printer', ref: '../../outside'),
        throwsA(isA<ProfileFormatException>()),
      );
      expect(sidecar.calls, isEmpty);
    });

    test('rejects unsafe profile ids before local path construction', () async {
      final tmp = await Directory.systemTemp.createTemp(
        'deckhand-profile-service-',
      );
      addTearDown(() async => tmp.delete(recursive: true));
      final sidecar = _FakeSidecar();
      final svc = SidecarProfileService(
        sidecar: sidecar,
        paths: DeckhandPaths(
          cacheDir: p.join(tmp.path, 'cache'),
          stateDir: p.join(tmp.path, 'state'),
          logsDir: p.join(tmp.path, 'logs'),
          settingsFile: p.join(tmp.path, 'settings.json'),
        ),
        security: _AllowAllSecurity(),
        localProfilesDir: tmp.path,
      );

      await expectLater(
        svc.ensureCached(profileId: '../escape'),
        throwsA(isA<ProfileFormatException>()),
      );
      expect(sidecar.calls, isEmpty);
    });
  });

  group('SidecarProfileService.fetchRegistry', () {
    test('parses printer-card hardware metadata from registry.yaml', () async {
      final tmp = await Directory.systemTemp.createTemp(
        'deckhand-profile-registry-',
      );
      addTearDown(() async => tmp.delete(recursive: true));
      await File(p.join(tmp.path, 'registry.yaml')).writeAsString('''
schema_version: 1
profiles:
  - id: test-printer
    display_name: Test Printer
    manufacturer: Acme
    model: Robo
    status: beta
    directory: printers/test-printer
    latest_tag: null
    sbc: RK3328
    kinematics: CoreXY
    mcu: STM32F407
    extras: ChromaKit
''');

      final svc = SidecarProfileService(
        sidecar: _FakeSidecar(),
        paths: DeckhandPaths(
          cacheDir: p.join(tmp.path, 'cache'),
          stateDir: p.join(tmp.path, 'state'),
          logsDir: p.join(tmp.path, 'logs'),
          settingsFile: p.join(tmp.path, 'settings.json'),
        ),
        security: _AllowAllSecurity(),
        localProfilesDir: tmp.path,
      );

      final registry = await svc.fetchRegistry();
      final entry = registry.entries.single;
      expect(entry.sbc, 'RK3328');
      expect(entry.kinematics, 'CoreXY');
      expect(entry.mcu, 'STM32F407');
      expect(entry.extras, 'ChromaKit');
    });
  });

  // TODO(test-hardware): end-to-end `SidecarProfileService.load` goes
  // through File I/O + an actual sidecar process for `ensureCached`.
  // That's covered in the wizard-level integration harness. The pure
  // parsing contract is fully covered here.
}

class _FakeSidecar implements SidecarConnection {
  final calls = <({String method, Map<String, dynamic> params})>[];

  @override
  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params,
  ) async {
    calls.add((method: method, params: params));
    return const <String, dynamic>{};
  }

  @override
  Stream<SidecarEvent> callStreaming(
    String method,
    Map<String, dynamic> params,
  ) => const Stream.empty();

  @override
  Stream<SidecarNotification> get notifications => const Stream.empty();

  @override
  Stream<SidecarNotification> subscribeToOperation(String operationId) =>
      const Stream.empty();

  @override
  Future<void> shutdown() async {}
}

class _AllowAllSecurity implements SecurityService {
  @override
  Future<ConfirmationToken> issueConfirmationToken({
    required String operation,
    required String target,
    Duration ttl = const Duration(seconds: 60),
  }) async => ConfirmationToken(
    value: 'token-0123456789abcdef',
    expiresAt: DateTime.now().add(ttl),
    operation: operation,
  );

  @override
  bool consumeToken(String value, String operation) => true;

  @override
  Future<Map<String, bool>> requestHostApprovals(List<String> hosts) async => {
    for (final host in hosts) host: true,
  };

  @override
  Future<bool> isHostAllowed(String host) async => true;

  @override
  Future<void> approveHost(String host) async {}

  @override
  Future<void> revokeHost(String host) async {}

  @override
  Future<List<String>> listApprovedHosts() async => const [];

  @override
  Future<void> pinHostFingerprint({
    required String host,
    required String fingerprint,
  }) async {}

  @override
  Future<String?> pinnedHostFingerprint(String host) async => null;

  @override
  Future<void> forgetHostFingerprint(String host) async {}

  @override
  Future<Map<String, String>> listPinnedFingerprints() async => const {};

  @override
  Future<String?> getGitHubToken() async => null;

  @override
  Future<void> setGitHubToken(String? token) async {}

  @override
  Stream<EgressEvent> get egressEvents => const Stream.empty();

  @override
  void recordEgress(EgressEvent event) {}
}
