import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PrinterProfile.fromJson', () {
    test('parses a minimal profile', () {
      final raw = <String, dynamic>{
        'schema_version': 1,
        'profile_id': 'test',
        'profile_version': '0.1.0',
        'display_name': 'Test Printer',
        'status': 'alpha',
        'required_hosts': ['github.com'],
        'hardware': {'architecture': 'aarch64'},
        'os': {
          'fresh_install_options': [
            {'id': 'img1', 'display_name': 'Image 1', 'url': 'http://x'},
          ],
        },
        'ssh': {
          'default_credentials': [
            {'user': 'mks', 'password': 'makerbase'},
          ],
        },
        'firmware': {
          'choices': [
            {
              'id': 'kalico',
              'display_name': 'Kalico',
              'repo': 'http://k',
              'ref': 'main',
            },
          ],
          'default_choice': 'kalico',
        },
        'mcus': [
          {'id': 'main', 'chip': 'stm32f407xx'},
        ],
        'screens': [
          {'id': 'arco_screen', 'recommended': true},
        ],
        'addons': [],
        'flows': {
          'stock_keep': {'enabled': true, 'steps': []},
        },
      };

      final p = PrinterProfile.fromJson(raw);
      expect(p.id, 'test');
      expect(p.version, '0.1.0');
      expect(p.displayName, 'Test Printer');
      expect(p.status, ProfileStatus.alpha);
      expect(p.requiredHosts, ['github.com']);
      expect(p.firmware.choices.length, 1);
      expect(p.firmware.choices.first.id, 'kalico');
      expect(p.firmware.defaultChoice, 'kalico');
      expect(p.mcus.length, 1);
      expect(p.mcus.first.id, 'main');
      expect(p.screens.length, 1);
      expect(p.screens.first.recommended, isTrue);
      expect(p.flows.stockKeep?.enabled, isTrue);
      expect(p.os.freshInstallOptions.length, 1);
    });

    test('defaults empty collections when missing', () {
      final p = PrinterProfile.fromJson(<String, dynamic>{
        'profile_id': 'empty',
        'profile_version': '0.0.0',
        'display_name': 'Empty',
        'status': 'stub',
      });
      expect(p.status, ProfileStatus.stub);
      expect(p.mcus, isEmpty);
      expect(p.screens, isEmpty);
      expect(p.addons, isEmpty);
      expect(p.stockOs.services, isEmpty);
    });

    test('parses stock_os inventory', () {
      final p = PrinterProfile.fromJson(<String, dynamic>{
        'profile_id': 't',
        'profile_version': '0.1.0',
        'display_name': 't',
        'status': 'alpha',
        'stock_os': {
          'services': [
            {'id': 'frpc', 'display_name': 'FRP', 'default_action': 'remove'},
          ],
          'files': [
            {
              'id': 'rsa_priv',
              'display_name': 'RSA private key',
              'paths': ['/a', '/b'],
              'default_action': 'delete',
            },
          ],
          'paths': [
            {
              'id': 'klipper',
              'path': '/home/mks/klipper',
              'action': 'snapshot_and_replace',
            },
          ],
        },
      });
      expect(p.stockOs.services.length, 1);
      expect(p.stockOs.services.first.id, 'frpc');
      expect(p.stockOs.files.single.paths, ['/a', '/b']);
      expect(p.stockOs.paths.single.action, 'snapshot_and_replace');
    });

    test('parses identification hints', () {
      final p = PrinterProfile.fromJson({
        'profile_id': 'x',
        'identification': {
          'moonraker_objects': ['phrozen_dev', 'some_other'],
          'hostname_patterns': [r'^mkspi$'],
        },
      });
      expect(p.identification.moonrakerObjects,
          ['phrozen_dev', 'some_other']);
      expect(p.identification.hostnamePatterns, [r'^mkspi$']);
    });

    test('identification defaults to empty when absent', () {
      final p = PrinterProfile.fromJson({'profile_id': 'x'});
      expect(p.identification.moonrakerObjects, isEmpty);
      expect(p.identification.hostnamePatterns, isEmpty);
      expect(p.identification.markerFile, isNull);
    });

    test('identification parses markerFile', () {
      final p = PrinterProfile.fromJson({
        'profile_id': 'x',
        'identification': {'marker_file': 'deckhand.json'},
      });
      expect(p.identification.markerFile, 'deckhand.json');
    });
  });

  group('PrinterMatch.score', () {
    const hints = ProfileIdentification(
      markerFile: 'deckhand.json',
      moonrakerObjects: ['phrozen_dev'],
      hostnamePatterns: [r'^mkspi$'],
    );

    test('marker file with matching profile_id => confirmed + reason', () {
      final m = PrinterMatch.score(
        hints: hints,
        markerFileContent: '{"profile_id": "phrozen-arco"}',
        hostname: null,
        registeredObjects: const [],
        profileId: 'phrozen-arco',
      );
      expect(m.confidence, PrinterMatchConfidence.confirmed);
      expect(m.reason, contains('phrozen-arco'));
    });

    test('marker file without profile_id match => still confirmed', () {
      final m = PrinterMatch.score(
        hints: hints,
        markerFileContent: '{"legacy": "yes"}',
        hostname: null,
        registeredObjects: const [],
        profileId: 'phrozen-arco',
      );
      expect(m.confidence, PrinterMatchConfidence.confirmed);
      expect(m.reason, contains('marker'));
    });

    test('object prefix match => confirmed', () {
      final m = PrinterMatch.score(
        hints: hints,
        markerFileContent: null,
        hostname: 'mkspi',
        registeredObjects: const ['phrozen_dev:runout', 'stepper_x'],
        profileId: 'phrozen-arco',
      );
      expect(m.confidence, PrinterMatchConfidence.confirmed);
      expect(m.reason, contains('phrozen_dev'));
    });

    test('hostname-only match => probable', () {
      final m = PrinterMatch.score(
        hints: hints,
        markerFileContent: null,
        hostname: 'mkspi',
        registeredObjects: const ['stepper_x'],
        profileId: 'phrozen-arco',
      );
      expect(m.confidence, PrinterMatchConfidence.probable);
      expect(m.reason, contains('mkspi'));
    });

    test('no signals, hints present => miss', () {
      final m = PrinterMatch.score(
        hints: hints,
        markerFileContent: null,
        hostname: 'octopi',
        registeredObjects: const ['stepper_x'],
        profileId: 'phrozen-arco',
      );
      expect(m.confidence, PrinterMatchConfidence.miss);
    });

    test('no hints at all => unknown (can\'t say either way)', () {
      final m = PrinterMatch.score(
        hints: const ProfileIdentification(),
        markerFileContent: null,
        hostname: 'octopi',
        registeredObjects: const [],
        profileId: 'x',
      );
      expect(m.confidence, PrinterMatchConfidence.unknown);
    });

    test('malformed hostname regex is skipped, not fatal', () {
      final m = PrinterMatch.score(
        hints: const ProfileIdentification(
          hostnamePatterns: [r'['], // invalid regex
        ),
        markerFileContent: null,
        hostname: 'whatever',
        registeredObjects: const [],
        profileId: 'x',
      );
      expect(m.confidence, PrinterMatchConfidence.miss);
    });
  });
}
