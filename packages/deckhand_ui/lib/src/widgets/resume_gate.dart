import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';

/// Pure-logic predicate for whether a saved [WizardState] is worth
/// surfacing to the user on next launch. An "initial" snapshot
/// (fresh app, no real progress) is not. Exposed so unit tests and
/// the welcome screen's RESUME panel both share one decision.
bool shouldOfferResume(WizardState? snapshot) {
  if (snapshot == null) return false;
  if (snapshot.currentStep == 'welcome' && snapshot.profileId.isEmpty) {
    return false;
  }
  return true;
}

/// Maps a persisted `currentStep` id to a GoRouter path. Known-unknown
/// steps fall back to welcome rather than guessing — safer for
/// resume.
///
/// Keep this in sync with the welcome screen's `_stepIdTagLabel`
/// table (the IdTag chip on the resume panel reads from that one);
/// any step shown to the user MUST be navigable here or clicking
/// Resume silently no-ops and the user is left stranded on welcome.
String? routeForResumeStep(String step) {
  const routes = <String, String>{
    'welcome': '/',
    'pick-printer': '/pick-printer',
    'connect': '/connect',
    'verify': '/verify',
    'choose-path': '/choose-path',
    'choose-os': '/choose-os',
    'flash-target': '/flash-target',
    'flash-confirm': '/flash-confirm',
    'first-boot': '/first-boot',
    'first-boot-setup': '/first-boot-setup',
    'firmware': '/firmware',
    'services': '/services',
    'files': '/files',
    'webui': '/webui',
    'screen-choice': '/screen-choice',
    'kiauh': '/kiauh',
    'snapshot': '/snapshot',
    'emmc-backup': '/emmc-backup',
    'hardening': '/hardening',
    'review': '/review',
    'progress': '/progress',
    'done': '/done',
    'manage': '/manage',
    'settings': '/settings',
  };
  return routes[step];
}

/// Pass-through widget. Earlier versions of Deckhand popped a modal
/// "Resume previous session?" dialog on launch; the new design
/// language (Deckhand Design Language.html, S10) surfaces resume as
/// a side-by-side panel on the welcome screen instead, so the modal
/// would double up and steal focus from the page that already
/// addresses it. The widget is kept (rather than ripped from the
/// shell tree) so the `WizardShell` layering stays stable and any
/// future at-launch interception has a place to land.
class ResumeGate extends StatelessWidget {
  const ResumeGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
