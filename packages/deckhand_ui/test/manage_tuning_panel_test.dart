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
