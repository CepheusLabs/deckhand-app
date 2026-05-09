import 'dart:convert';
import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/providers.dart';
import 'package:deckhand_ui/src/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'helpers.dart';

void main() {
  testWidgets('SettingsScreen can run preflight on demand', (tester) async {
    final settings = _MemorySettings();
    final doctor = _CountingDoctor(
      const DoctorReport(
        passed: false,
        results: [
          DoctorResult(
            name: 'elevated_helper',
            status: DoctorStatus.fail,
            detail: 'helper missing',
          ),
        ],
        report: '[FAIL] elevated_helper — helper missing',
      ),
    );
    final controller = stubWizardController(profileJson: testProfileJson());
    await controller.loadProfile('test-printer');

    await tester.pumpWidget(
      testHarness(
        controller: controller,
        child: const SettingsScreen(),
        initialLocation: '/settings',
        doctor: doctor,
        extraOverrides: [deckhandSettingsProvider.overrideWithValue(settings)],
      ),
    );

    expect(find.text('Run preflight'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Run preflight'));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(doctor.calls, 1);
    expect(find.textContaining('Preflight found 1 issue'), findsOneWidget);
    expect(find.textContaining('elevated_helper'), findsOneWidget);
    expect(settings.lastPreflight?['passed'], isFalse);
  });

  testWidgets('Preflight cache rolls back when saving fails', (tester) async {
    final settings =
        _MemorySettings(
            saveError: StateError(
              r'write settings failed on \\.\PHYSICALDRIVE3',
            ),
          )
          ..lastPreflight = {
            'passed': true,
            'results': <Map<String, Object?>>[],
            'report': '[PASS] cached',
            'at': '2026-05-04T12:00:00.000Z',
          };
    final doctor = _CountingDoctor(
      const DoctorReport(
        passed: false,
        results: [
          DoctorResult(
            name: 'disks_enumerate',
            status: DoctorStatus.fail,
            detail: 'Get-Disk failed',
          ),
        ],
        report: '[FAIL] disks_enumerate — Get-Disk failed',
      ),
    );
    final controller = stubWizardController(profileJson: testProfileJson());
    await controller.loadProfile('test-printer');

    await tester.pumpWidget(
      testHarness(
        controller: controller,
        child: const SettingsScreen(),
        initialLocation: '/settings',
        doctor: doctor,
        extraOverrides: [deckhandSettingsProvider.overrideWithValue(settings)],
      ),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Run preflight'));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(doctor.calls, 1);
    expect(settings.lastPreflight?['passed'], isTrue);
    expect(settings.lastPreflight?['report'], '[PASS] cached');
    expect(find.textContaining('Windows disk 3'), findsOne);
    expect(find.textContaining('PHYSICALDRIVE3'), findsNothing);
  });

  testWidgets('SettingsScreen lists and deletes cached OS images', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('deckhand-os-cache-ui-');
    addTearDown(() => root.deleteSync(recursive: true));
    final image = File(p.join(root.path, 'arco.img'));
    image.writeAsBytesSync(List<int>.filled(2048, 1));
    File('${image.path}$osImageDownloadManifestSuffix').writeAsStringSync(
      jsonEncode({
        'schema_version': 1,
        'url': 'https://github.com/armbian/community/releases/download/x.img',
        'path': image.path,
        'expected_sha256': 'a' * 64,
        'actual_sha256': 'a' * 64,
        'downloaded_at': '2026-05-04T12:00:00Z',
      }),
    );
    File('${image.path}.part').writeAsBytesSync([1]);
    final entry = OsImageCacheEntry(
      imagePath: image.path,
      bytes: image.lengthSync(),
      modifiedAt: DateTime.utc(2026, 5, 4, 12),
      url: 'https://github.com/armbian/community/releases/download/x.img',
      expectedSha256: 'a' * 64,
      actualSha256: 'a' * 64,
      downloadedAt: DateTime.utc(2026, 5, 4, 12),
      manifestPath: '${image.path}$osImageDownloadManifestSuffix',
    );

    final controller = stubWizardController(profileJson: testProfileJson());
    await controller.loadProfile('test-printer');

    await tester.pumpWidget(
      testHarness(
        controller: controller,
        child: const SettingsScreen(),
        initialLocation: '/settings',
        extraOverrides: [
          osImagesDirProvider.overrideWithValue(root.path),
          osImageCacheProvider.overrideWith((ref) async => [entry]),
          osImageCacheDeleteProvider.overrideWithValue(({
            required String imagePath,
          }) async {
            File(imagePath).deleteSync();
            File('$imagePath$osImageDownloadManifestSuffix').deleteSync();
            File('$imagePath.part').deleteSync();
          }),
        ],
      ),
    );
    await tester.pump();

    expect(find.text('OS IMAGE CACHE'), findsOneWidget);
    expect(find.text('arco.img'), findsOneWidget);
    expect(find.text('VERIFIED'), findsOneWidget);
    expect(find.textContaining('github.com'), findsOneWidget);

    await tester.ensureVisible(find.widgetWithText(OutlinedButton, 'Delete'));
    await tester.pump();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Delete'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump(const Duration(milliseconds: 250));

    expect(image.existsSync(), isFalse);
    expect(
      File('${image.path}$osImageDownloadManifestSuffix').existsSync(),
      isFalse,
    );
    expect(File('${image.path}.part').existsSync(), isFalse);
  });

  testWidgets('SettingsScreen clears stale OS image cache files', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('deckhand-os-cache-ui-');
    addTearDown(() => root.deleteSync(recursive: true));
    final files = [
      File(p.join(root.path, 'arco.img')),
      File(p.join(root.path, 'arco.img.part')),
      File(p.join(root.path, 'arco.img.download.part')),
      File(p.join(root.path, 'arco.img.deckhand-download.json')),
    ];
    for (final file in files) {
      file.writeAsBytesSync([1]);
    }
    final controller = stubWizardController(profileJson: testProfileJson());
    await controller.loadProfile('test-printer');

    await tester.pumpWidget(
      testHarness(
        controller: controller,
        child: const SettingsScreen(),
        initialLocation: '/settings',
        extraOverrides: [
          osImagesDirProvider.overrideWithValue(root.path),
          osImageCacheClearProvider.overrideWithValue(() async {
            for (final file in files) {
              if (file.existsSync()) file.deleteSync();
            }
            return files.length;
          }),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    await tester.ensureVisible(find.widgetWithText(TextButton, 'Clear cache'));
    await tester.tap(find.widgetWithText(TextButton, 'Clear cache'));
    await tester.pump();
    expect(find.text('Clear OS image cache?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Clear cache'));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump(const Duration(milliseconds: 250));

    for (final file in files) {
      expect(file.existsSync(), isFalse);
    }
    expect(find.textContaining('Cleared 4 OS image cache files'), findsOne);
  });

  testWidgets('SettingsScreen sanitizes OS image cache errors', (tester) async {
    final controller = stubWizardController(profileJson: testProfileJson());
    await controller.loadProfile('test-printer');

    await tester.pumpWidget(
      testHarness(
        controller: controller,
        child: const SettingsScreen(),
        initialLocation: '/settings',
        extraOverrides: [
          osImageCacheProvider.overrideWith(
            (ref) async =>
                throw StateError(r'read \\.\PHYSICALDRIVE3: Access is denied.'),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('Could not read OS image cache'), findsOne);
    expect(find.textContaining('Windows disk 3'), findsOne);
    expect(find.textContaining('PHYSICALDRIVE3'), findsNothing);
    expect(find.textContaining('StateError'), findsNothing);
  });

  testWidgets('Developer mode toggle rolls back when saving fails', (
    tester,
  ) async {
    final settings = _MemorySettings(
      saveError: StateError(r'write settings failed on \\.\PHYSICALDRIVE3'),
    );
    final controller = stubWizardController(profileJson: testProfileJson());
    await controller.loadProfile('test-printer');

    await tester.pumpWidget(
      testHarness(
        controller: controller,
        child: const SettingsScreen(),
        initialLocation: '/settings',
        extraOverrides: [deckhandSettingsProvider.overrideWithValue(settings)],
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Advanced'));
    await tester.pump();
    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    final toggle = tester.widget<Switch>(find.byType(Switch));
    expect(toggle.value, isFalse);
    expect(settings.developerMode, isFalse);
    expect(find.textContaining('Could not save developer mode'), findsOne);
    expect(find.textContaining('Windows disk 3'), findsOne);
    expect(find.textContaining('PHYSICALDRIVE3'), findsNothing);
  });

  testWidgets('General settings roll back when saving fails', (tester) async {
    final settings =
        _MemorySettings(
            saveError: StateError(
              r'write settings failed on \\.\PHYSICALDRIVE3',
            ),
          )
          ..verifyAfterWrite = true
          ..cacheRetentionDays = 30;
    final controller = stubWizardController(profileJson: testProfileJson());
    await controller.loadProfile('test-printer');

    await tester.pumpWidget(
      testHarness(
        controller: controller,
        child: const SettingsScreen(),
        initialLocation: '/settings',
        extraOverrides: [deckhandSettingsProvider.overrideWithValue(settings)],
      ),
    );
    await tester.pump();

    await tester.ensureVisible(find.text('Verify after flash'));
    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    await tester.enterText(find.byType(TextField).first, '7');
    await tester.ensureVisible(
      find.widgetWithText(FilledButton, 'Save general settings'),
    );
    await tester.tap(
      find.widgetWithText(FilledButton, 'Save general settings'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(settings.verifyAfterWrite, isTrue);
    expect(settings.cacheRetentionDays, 30);
    expect(find.textContaining('Windows disk 3'), findsOne);
    expect(find.textContaining('PHYSICALDRIVE3'), findsNothing);
  });

  testWidgets('Profile source rolls back when saving fails', (tester) async {
    final settings = _MemorySettings(
      saveError: StateError(r'write settings failed on \\.\PHYSICALDRIVE3'),
    )..localProfilesDir = 'C:\\deckhand\\old-profiles';
    final controller = stubWizardController(profileJson: testProfileJson());
    await controller.loadProfile('test-printer');

    await tester.pumpWidget(
      testHarness(
        controller: controller,
        child: const SettingsScreen(),
        initialLocation: '/settings',
        extraOverrides: [deckhandSettingsProvider.overrideWithValue(settings)],
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Profiles'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '');
    await tester.ensureVisible(
      find.widgetWithText(FilledButton, 'Save profile source'),
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save profile source'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(settings.localProfilesDir, 'C:\\deckhand\\old-profiles');
    expect(find.textContaining('Windows disk 3'), findsOne);
    expect(find.textContaining('PHYSICALDRIVE3'), findsNothing);
  });
}

class _MemorySettings extends DeckhandSettings {
  _MemorySettings({this.saveError}) : super(path: '<memory>');

  final Object? saveError;

  @override
  Future<void> save() async {
    final error = saveError;
    if (error != null) {
      throw error;
    }
  }
}

class _CountingDoctor implements DoctorService {
  _CountingDoctor(this.report);

  final DoctorReport report;
  int calls = 0;

  @override
  Future<DoctorReport> run() async {
    calls++;
    return report;
  }
}
