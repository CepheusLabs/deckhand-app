import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure-logic tests for the "is this state worth saving?" predicate
/// that gates wizardStateProvider's writes. The chrome's bootstrap
/// fire used to wipe the saved snapshot on every launch — these
/// tests pin the predicate so a future refactor can't reintroduce
/// that regression.
void main() {
  group('themeModeProvider', () {
    test('rolls runtime state back when saving the preference fails', () async {
      final settings = _ThrowingSettings();
      final container = ProviderContainer(
        overrides: [deckhandSettingsProvider.overrideWithValue(settings)],
      );
      addTearDown(container.dispose);

      expect(container.read(themeModeProvider), ThemeMode.system);

      await container.read(themeModeProvider.notifier).set(ThemeMode.dark);

      expect(container.read(themeModeProvider), ThemeMode.system);
      expect(settings.themeModeName, 'system');
      expect(settings.saveCalls, 1);
    });
  });

  group('preflightReportProvider', () {
    test('returns the live report when first-run cache save fails', () async {
      final settings = _ThrowingSettings();
      final doctor = _StaticDoctor(
        const DoctorReport(
          passed: true,
          results: [
            DoctorResult(
              name: 'runtime',
              status: DoctorStatus.pass,
              detail: 'ok',
            ),
          ],
          report: '[PASS] runtime - ok',
        ),
      );
      final container = ProviderContainer(
        overrides: [
          deckhandSettingsProvider.overrideWithValue(settings),
          doctorServiceProvider.overrideWithValue(doctor),
        ],
      );
      addTearDown(container.dispose);

      final report = await container.read(preflightReportProvider.future);
      await Future<void>.delayed(Duration.zero);

      expect(report.passed, isTrue);
      expect(doctor.calls, 1);
      expect(settings.saveCalls, 1);
    });

    test('decodes malformed cached result maps defensively', () async {
      final settings = DeckhandSettings(
        path: '<memory>',
        initial: {
          'last_preflight': {
            'passed': true,
            'report': '[PASS] cached',
            'results': [
              <Object?, Object?>{
                42: 'ignored',
                'name': 'runtime',
                'status': 'PASS',
                'detail': 'ok',
              },
            ],
          },
        },
      );
      final container = ProviderContainer(
        overrides: [
          deckhandSettingsProvider.overrideWithValue(settings),
          doctorServiceProvider.overrideWithValue(
            _StaticDoctor(
              const DoctorReport(passed: true, results: [], report: ''),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final report = await container.read(preflightReportProvider.future);

      expect(report.passed, isTrue);
      expect(report.results.single.name, 'runtime');
      expect(report.results.single.status, DoctorStatus.pass);
      expect(report.results.single.detail, 'ok');
    });

    test('drops malformed cached preflight result fields', () async {
      final settings = DeckhandSettings(
        path: '<memory>',
        initial: {
          'last_preflight': {
            'passed': 'yes',
            'report': 42,
            'results': [
              {'name': 99, 'status': 17, 'detail': false},
              {'name': 'powershell', 'status': 'WARN', 'detail': 'slow'},
            ],
          },
        },
      );
      final container = ProviderContainer(
        overrides: [
          deckhandSettingsProvider.overrideWithValue(settings),
          doctorServiceProvider.overrideWithValue(
            _StaticDoctor(
              const DoctorReport(passed: true, results: [], report: ''),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final report = await container.read(preflightReportProvider.future);

      expect(report.passed, isFalse);
      expect(report.report, '');
      expect(report.results.map((r) => r.name), ['', 'powershell']);
      expect(report.results.first.status, DoctorStatus.unknown);
      expect(report.results.first.detail, '');
      expect(report.results.last.status, DoctorStatus.warn);
    });
  });

  group('isPersistableWizardState', () {
    test('initial state (welcome + empty profile + no decisions) is NOT '
        'persistable', () {
      // The boot-time chrome fire happens with this exact value.
      // Persisting it would clobber whatever resume snapshot is on
      // disk before the user has committed to anything new.
      expect(isPersistableWizardState(WizardState.initial()), isFalse);
    });

    test('a state with a profileId IS persistable, even at currentStep '
        '"welcome"', () {
      // The user picked a printer (profileId set) but hasn't navigated
      // past welcome. Worth saving — they've made a real decision.
      const s = WizardState(
        profileId: 'phrozen-arco',
        decisions: {},
        currentStep: 'welcome',
        flow: WizardFlow.none,
      );
      expect(isPersistableWizardState(s), isTrue);
    });

    test('a state with decisions IS persistable, even with no profileId', () {
      // Edge case — the profile load failed but some decisions were
      // recorded in the meantime. Don't lose them.
      const s = WizardState(
        profileId: '',
        decisions: {'something': 'value'},
        currentStep: 'welcome',
        flow: WizardFlow.none,
      );
      expect(isPersistableWizardState(s), isTrue);
    });

    test('a fully populated mid-wizard state IS persistable', () {
      const s = WizardState(
        profileId: 'phrozen-arco',
        decisions: {'flash.disk': 'PhysicalDrive3'},
        currentStep: 'emmc-backup',
        flow: WizardFlow.freshFlash,
      );
      expect(isPersistableWizardState(s), isTrue);
    });

    test('navigating past welcome WITHOUT picking a printer is NOT '
        'persistable', () {
      // Specifically guards the regression path: the router listener
      // updates currentStep on every nav, so a user who clicks
      // "Start a new install" lands on /pick-printer with state
      // currentStep='pick-printer' but no profileId yet. That state
      // must not overwrite a real saved session — they haven't
      // committed to discarding it.
      const s = WizardState(
        profileId: '',
        decisions: {},
        currentStep: 'pick-printer',
        flow: WizardFlow.none,
      );
      expect(isPersistableWizardState(s), isFalse);
    });
  });
}

class _ThrowingSettings extends DeckhandSettings {
  _ThrowingSettings() : super(path: '<memory>');

  int saveCalls = 0;

  @override
  Future<void> save() async {
    saveCalls++;
    throw StateError('settings save failed');
  }
}

class _StaticDoctor implements DoctorService {
  _StaticDoctor(this.report);

  final DoctorReport report;
  int calls = 0;

  @override
  Future<DoctorReport> run() async {
    calls++;
    return report;
  }
}
