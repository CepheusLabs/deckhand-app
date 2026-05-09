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
        'addons': <Map<String, Object?>>[],
        'flows': {
          'stock_keep': {'enabled': true, 'steps': <Map<String, Object?>>[]},
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

    test('stock file default action is keep unless explicitly delete', () {
      final p = PrinterProfile.fromJson(<String, dynamic>{
        'profile_id': 't',
        'stock_os': {
          'files': [
            {
              'id': 'rsa_priv',
              'paths': ['/etc/dropbear/dropbear_rsa_host_key'],
            },
          ],
        },
      });
      expect(p.stockOs.files.single.defaultAction, 'keep');
    });

    test(
      'throws ProfileFormatException for missing critical required fields',
      () {
        expect(
          () => PrinterProfile.fromJson(<String, dynamic>{
            'profile_id': 'broken',
            'ssh': {
              'default_credentials': [
                {'password': 'pw'},
              ],
            },
          }),
          throwsA(isA<ProfileFormatException>()),
        );
      },
    );

    test('parses identification hints', () {
      final p = PrinterProfile.fromJson({
        'profile_id': 'x',
        'identification': {
          'moonraker_objects': ['phrozen_dev', 'some_other'],
          'hostname_patterns': [r'^mkspi$'],
        },
      });
      expect(p.identification.moonrakerObjects, ['phrozen_dev', 'some_other']);
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

    test('drops malformed optional list entries instead of crashing', () {
      final p = PrinterProfile.fromJson({
        'profile_id': 'x',
        'required_hosts': ['github.com', 7, null, 'api.github.com'],
        'identification': {
          'moonraker_objects': ['phrozen_dev', false],
          'hostname_patterns': [
            r'^mkspi$',
            {'bad': 'entry'},
          ],
        },
        'hardware': {
          'features': ['enclosed', 42],
        },
        'stock_os': {
          'files': [
            {
              'id': 'config',
              'paths': ['/home/mks/printer_data/config', 10],
            },
          ],
        },
      });

      expect(p.requiredHosts, ['github.com', 'api.github.com']);
      expect(p.identification.moonrakerObjects, ['phrozen_dev']);
      expect(p.identification.hostnamePatterns, [r'^mkspi$']);
      expect(p.hardware.features, ['enclosed']);
      expect(p.stockOs.files.single.paths, ['/home/mks/printer_data/config']);
    });

    test('drops malformed optional maps instead of crashing', () {
      final p = PrinterProfile.fromJson({
        'profile_id': 'x',
        'hardware': {
          'sbc': {1: 'bad key', 'board': 'MKS Pi'},
          'steppers': [
            {'id': 'x'},
            {1: 'bad key', 'id': 'y'},
          ],
        },
        'stack': {
          'moonraker': {1: 'bad key', 'repo': 'https://github.com/a/b'},
        },
      });

      expect(p.hardware.sbc?.board, 'MKS Pi');
      expect(p.hardware.steppers, [
        {'id': 'x'},
        {'id': 'y'},
      ]);
      expect(p.stack.moonraker, {'repo': 'https://github.com/a/b'});
    });

    test('snapshot path optional metadata is tolerant', () {
      final p = PrinterProfile.fromJson({
        'profile_id': 'x',
        'stock_os': {
          'snapshot_paths': [
            {
              'id': 'printer_config',
              'path': '~/printer_data/config',
              'display_name': 42,
              'default_selected': 'yes',
              'helper_text': ['not text'],
            },
          ],
        },
      });

      final path = p.stockOs.snapshotPaths.single;
      expect(path.id, 'printer_config');
      expect(path.displayName, 'printer_config');
      expect(path.path, '~/printer_data/config');
      expect(path.defaultSelected, isTrue);
      expect(path.helperText, isNull);
    });

    test('drops malformed optional scalar metadata instead of crashing', () {
      final p = PrinterProfile.fromJson({
        'profile_id': 'x',
        'profile_version': 7,
        'display_name': ['bad'],
        'status': false,
        'manufacturer': 10,
        'model': {'bad': true},
        'identification': {
          'marker_file': ['deckhand.json'],
          'probe_timeout_seconds': '9',
        },
        'hardware': {
          'architecture': 42,
          'kinematics': ['cartesian'],
          'sbc': {'soc': 1, 'board': false, 'emmc_size_bytes': '8GiB'},
        },
        'os': {
          'stock': {
            'distro': 42,
            'version': ['x'],
            'codename': false,
            'python': {'bad': true},
            'notes': 9,
          },
          'boot_mode': ['emmc'],
          'fresh_install_options': [
            {
              'id': 'img',
              'url': 'https://example.com/img.xz',
              'display_name': 42,
              'recommended': 'yes',
              'size_bytes_approx': 'large',
              'architecture': false,
              'notes': ['bad'],
            },
          ],
        },
        'ssh': {
          'default_port': '22',
          'recommended_user_after_install': 42,
          'default_credentials': [
            {'user': 'mks', 'password': 10, 'key_path': false},
          ],
        },
        'firmware': {
          'default_choice': ['kalico'],
          'replace_stock_in_place': 'true',
          'snapshot_before_replace': 1,
          'choices': [
            {
              'id': 'kalico',
              'repo': 'https://github.com/KalicoCrew/kalico',
              'display_name': 42,
              'ref': ['main'],
              'description': 7,
              'install_path': false,
              'venv_path': 9,
              'python_min': ['3.11'],
              'recommended': 'yes',
            },
          ],
        },
        'mcus': [
          {'id': 'main', 'display_name': 42},
        ],
        'screens': [
          {
            'id': 'screen',
            'display_name': 42,
            'status': false,
            'recommended': 'yes',
          },
        ],
        'addons': [
          {'id': 'addon', 'kind': 42, 'display_name': false},
        ],
        'stock_os': {
          'detections': [
            {'kind': 'service', 'required': 'yes'},
          ],
          'services': [
            {'id': 'frpc', 'display_name': 42, 'default_action': false},
          ],
          'files': [
            {'id': 'cache', 'display_name': 42, 'default_action': false},
          ],
          'paths': [
            {
              'id': 'config',
              'path': '/config',
              'action': false,
              'snapshot_to': 42,
              'role': ['config'],
            },
          ],
        },
        'wizard': {'title': 42},
        'flows': {
          'stock_keep': {'enabled': 'true'},
        },
      });

      expect(p.version, '0.0.0');
      expect(p.displayName, '');
      expect(p.status, ProfileStatus.alpha);
      expect(p.identification.markerFile, isNull);
      expect(p.identification.probeTimeoutSeconds, 3);
      expect(p.hardware.architecture, isNull);
      expect(p.hardware.sbc?.emmcSizeBytes, isNull);
      expect(p.os.bootMode, isNull);
      expect(p.os.stock?.distro, isNull);
      expect(p.os.freshInstallOptions.single.displayName, 'img');
      expect(p.os.freshInstallOptions.single.recommended, isFalse);
      expect(p.ssh.defaultPort, 22);
      expect(p.ssh.defaultCredentials.single.password, isNull);
      expect(p.firmware.defaultChoice, isNull);
      expect(p.firmware.replaceStockInPlace, isTrue);
      expect(p.firmware.choices.single.ref, 'main');
      expect(p.firmware.choices.single.recommended, isFalse);
      expect(p.mcus.single.displayName, isNull);
      expect(p.screens.single.recommended, isFalse);
      expect(p.addons.single.kind, isNull);
      expect(p.stockOs.detections.single.required, isTrue);
      expect(p.stockOs.services.single.displayName, 'frpc');
      expect(p.stockOs.files.single.defaultAction, 'keep');
      expect(p.stockOs.paths.single.action, 'preserve');
      expect(p.wizard.title, isNull);
      expect(p.flows.stockKeep?.enabled, isFalse);
    });

    test('throws ProfileFormatException for malformed build volume', () {
      expect(
        () => PrinterProfile.fromJson({
          'profile_id': 'x',
          'hardware': {
            'build_volume_mm': {'x': 300, 'y': '300', 'z': 300},
          },
        }),
        throwsA(isA<ProfileFormatException>()),
      );
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
