import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/widgets/resume_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shouldOfferResume', () {
    test('null snapshot -> no prompt', () {
      expect(shouldOfferResume(null), isFalse);
    });

    test('initial snapshot -> no prompt (fresh app, nothing to resume)', () {
      expect(shouldOfferResume(WizardState.initial()), isFalse);
    });

    test('welcome screen with a profileId still offers resume', () {
      // User got as far as picking a printer and then killed the app.
      // That counts as progress worth resuming, even if they're still
      // at `welcome` because pick_printer hasn't committed yet.
      const s = WizardState(
        profileId: 'sovol-zero',
        decisions: {},
        currentStep: 'welcome',
        flow: WizardFlow.none,
      );
      expect(shouldOfferResume(s), isTrue);
    });

    test('mid-wizard snapshot -> prompt', () {
      const s = WizardState(
        profileId: 'phrozen-arco',
        decisions: {'firmware': 'kalico'},
        currentStep: 'verify',
        flow: WizardFlow.stockKeep,
      );
      expect(shouldOfferResume(s), isTrue);
    });
  });

  group('routeForResumeStep', () {
    test('known steps map to their router path', () {
      expect(routeForResumeStep('welcome'), '/');
      expect(routeForResumeStep('connect'), '/connect');
      expect(routeForResumeStep('verify'), '/verify');
      expect(routeForResumeStep('progress'), '/progress');
      expect(routeForResumeStep('done'), '/done');
    });

    test('snapshot/emmc-backup steps are navigable', () {
      // Regression: clicking Resume with a saved snapshot at
      // currentStep='emmc-backup' silently no-op'd because the
      // route table didn't include it, leaving the user stranded
      // on welcome. Both snapshot-flow steps must be present.
      expect(routeForResumeStep('snapshot'), '/snapshot');
      expect(routeForResumeStep('emmc-backup'), '/emmc-backup');
    });

    test('manage and settings are navigable resume targets', () {
      // currentStep tracks every routed location now (via the
      // WizardShell router listener), so a user who closed the app
      // on /manage or /settings must be able to land back there.
      expect(routeForResumeStep('manage'), '/manage');
      expect(routeForResumeStep('settings'), '/settings');
    });

    test('manager and recovery routes are navigable resume targets', () {
      // Router-driven currentStep tokens are route paths without the
      // leading slash. Keep every non-ephemeral app route resumable so
      // closing on a manager/recovery page does not fall back to the
      // install wizard.
      expect(routeForResumeStep('printers'), '/printers');
      expect(routeForResumeStep('manage-emmc-backup'), '/manage-emmc-backup');
      expect(
        routeForResumeStep('recovery-emmc-backup'),
        '/recovery-emmc-backup',
      );
      expect(routeForResumeStep('emmc-restore'), '/emmc-restore');
    });

    test('unknown step returns null — caller falls back to welcome', () {
      expect(routeForResumeStep('time-travel'), isNull);
      expect(routeForResumeStep(''), isNull);
    });
  });
}
