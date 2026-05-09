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
}

class _MemorySettings extends DeckhandSettings {
  _MemorySettings() : super(path: '<memory>');

  @override
  Future<void> save() async {}
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
