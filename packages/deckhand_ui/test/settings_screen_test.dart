import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/providers.dart';
import 'package:deckhand_ui/src/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
