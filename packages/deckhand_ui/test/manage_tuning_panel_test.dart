import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/providers.dart';
import 'package:deckhand_ui/src/screens/manage_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  testWidgets('tuning tab sends Moonraker calibration gcode', (tester) async {
    final controller = stubWizardController(profileJson: testProfileJson());
    await controller.loadProfile('test-printer');
    controller.setSession(
      const SshSession(id: 's', host: '192.168.1.50', port: 22, user: 'root'),
    );
    final moonraker = _FakeMoonraker();

    await tester.pumpWidget(
      testHarness(
        controller: controller,
        child: const ManageScreen(),
        initialLocation: '/manage',
        extraOverrides: [moonrakerServiceProvider.overrideWithValue(moonraker)],
      ),
    );

    await tester.tap(find.text('Tune'));
    await tester.pumpAndSettle();
    expect(find.text('LIVE PRINTER'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Run').first);
    await tester.pump();

    expect(
      moonraker.scripts,
      contains('PID_CALIBRATE HEATER=extruder TARGET=215'),
    );
  });

  testWidgets('tuning tab previews and applies managed printer cfg', (
    tester,
  ) async {
    final controller = stubWizardController(profileJson: testProfileJson());
    await controller.loadProfile('test-printer');
    controller.setSession(
      const SshSession(id: 's', host: '192.168.1.50', port: 22, user: 'mks'),
    );
    final moonraker = _FakeMoonraker();
    final config = _FakePrinterConfigService();

    await tester.pumpWidget(
      testHarness(
        controller: controller,
        child: const ManageScreen(),
        initialLocation: '/manage',
        extraOverrides: [
          moonrakerServiceProvider.overrideWithValue(moonraker),
          printerConfigServiceProvider.overrideWithValue(config),
        ],
      ),
    );

    await tester.tap(find.text('Tune'));
    await tester.pumpAndSettle();

    expect(find.text('MANAGED PRINTER.CFG'), findsOneWidget);
    expect(find.textContaining('pressure_advance: 0.040'), findsOneWidget);

    final previewButton = find.widgetWithText(OutlinedButton, 'Preview');
    await tester.ensureVisible(previewButton);
    await tester.pumpAndSettle();
    await tester.tap(previewButton);
    await tester.pumpAndSettle();

    expect(config.readPaths, contains('~/printer_data/config/printer.cfg'));
    expect(find.text('Preview ready - pending change'), findsOneWidget);

    final applyButton = find.widgetWithText(
      OutlinedButton,
      'Apply with backup',
    );
    await tester.ensureVisible(applyButton);
    await tester.pumpAndSettle();
    await tester.tap(applyButton);
    await tester.pumpAndSettle();

    expect(config.appliedPath, '~/printer_data/config/printer.cfg');
    expect(config.appliedSection, 'extruder');
    expect(config.appliedValues['pressure_advance'], '0.040');
    expect(config.appliedValues['rotation_distance'], '7.5000');
    expect(find.textContaining('backup at'), findsOneWidget);
  });
}

class _FakeMoonraker implements MoonrakerService {
  final scripts = <String>[];

  @override
  Future<KlippyInfo> info({required String host, int port = 7125}) async =>
      const KlippyInfo(
        state: 'ready',
        hostname: 'arco-bench',
        softwareVersion: 'v0.12',
        klippyState: 'ready',
      );

  @override
  Future<bool> isPrinting({required String host, int port = 7125}) async =>
      false;

  @override
  Future<Map<String, dynamic>> queryObjects({
    required String host,
    int port = 7125,
    required List<String> objects,
  }) async => const {
    'print_stats': {'state': 'idle'},
    'extruder': {'temperature': 213.0},
    'heater_bed': {'temperature': 68.0},
    'configfile': {
      'settings': {
        'extruder': {'rotation_distance': 7.5},
      },
    },
  };

  @override
  Future<void> runGCode({
    required String host,
    int port = 7125,
    required String script,
  }) async {
    scripts.add(script);
  }

  @override
  Future<List<String>> listObjects({
    required String host,
    int port = 7125,
  }) async => const [];

  @override
  Future<String?> fetchConfigFile({
    required String host,
    int port = 7125,
    required String filename,
  }) async => null;
}

class _FakePrinterConfigService implements PrinterConfigService {
  final readPaths = <String>[];
  String? appliedPath;
  String? appliedSection;
  Map<String, String> appliedValues = const {};

  @override
  Future<PrinterConfigDocument> read(
    SshSession session, {
    required String path,
  }) async {
    readPaths.add(path);
    return PrinterConfigDocument(
      path: path,
      content: '[printer]\nkinematics: cartesian\n',
    );
  }

  @override
  PrinterConfigPreview previewSectionSettings({
    required String original,
    required String section,
    required Map<String, String> values,
  }) {
    return previewKlipperSectionSettings(
      original: original,
      section: section,
      values: values,
    );
  }

  @override
  Future<PrinterConfigApplyResult> applySectionSettings(
    SshSession session, {
    required String path,
    required String section,
    required Map<String, String> values,
  }) async {
    appliedPath = path;
    appliedSection = section;
    appliedValues = Map<String, String>.of(values);
    return PrinterConfigApplyResult(
      path: path,
      backupPath: '$path.deckhand-pre-test',
      changed: true,
    );
  }
}
