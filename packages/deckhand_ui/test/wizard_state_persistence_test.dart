import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/providers.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure-logic tests for the "is this state worth saving?" predicate
/// that gates wizardStateProvider's writes. The chrome's bootstrap
/// fire used to wipe the saved snapshot on every launch — these
/// tests pin the predicate so a future refactor can't reintroduce
/// that regression.
void main() {
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
