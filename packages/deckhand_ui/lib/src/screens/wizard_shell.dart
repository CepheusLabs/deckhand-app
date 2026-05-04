import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../router.dart';
import '../theming/deckhand_theme.dart';
import '../widgets/resume_gate.dart';

/// Top-level widget for the Deckhand desktop app. Wires GoRouter +
/// Material 3 theme. The bootstrapper (app/lib/main.dart) wraps this
/// in a [ProviderScope] with the concrete service implementations.
///
/// The design-language chrome (titlebar + sidenav + footbar) is
/// installed via a [ShellRoute] inside [buildDeckhandRouter] rather
/// than the `MaterialApp.router` builder — that placement lets
/// `GoRouterState.of(context)` work inside the chrome, which
/// `MaterialApp.router.builder` does not (it sits above the route
/// subtree).
///
/// The [GoRouter] instance is held in widget state, NOT recreated on
/// every build. Recreating it would reset the route stack on any
/// rebuild (e.g. theme toggle), kicking the user back to the
/// welcome screen mid-wizard. Stateful ownership keeps navigation
/// stable across orthogonal rebuilds.
///
/// [ResumeGate] runs once after the first frame and offers to
/// restore a prior wizard session if the on-disk snapshot has
/// progressed past the welcome screen.
class WizardShell extends ConsumerStatefulWidget {
  const WizardShell({super.key});

  @override
  ConsumerState<WizardShell> createState() => _WizardShellState();
}

class _WizardShellState extends ConsumerState<WizardShell>
    with WidgetsBindingObserver {
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    _router = buildDeckhandRouter();
    // Mirror every navigation through GoRouter into the wizard
    // controller's currentStep so the on-disk snapshot tracks where
    // the user actually is. Without this, currentStep stays the
    // initial 'welcome' value forever and the resume panel always
    // shows "S10 · welcome" no matter how deep the user got.
    // routerDelegate is a ChangeNotifier; addListener fires after
    // every successful navigation. The first fire happens on the
    // initial route, which is the welcome step and therefore a
    // no-op via setCurrentStep's idempotence guard.
    _router.routerDelegate.addListener(_syncCurrentStep);
    // Hook the app lifecycle so [didRequestAppExit] gets called when
    // the user closes the window — that's the last chance to flush a
    // pending wizard-state save before the process dies. The
    // event-driven save in `wizardStateProvider` fires
    // unawaited(store.save) on every controller event; if the user
    // makes a decision and immediately closes, the inflight write may
    // not have hit disk yet.
    WidgetsBinding.instance.addObserver(this);
    // Kick the host-disk enumeration off in the background as soon as
    // the shell mounts. listDisks() is slow on Windows (PowerShell
    // Get-Disk + Get-Partition + a sentinel-dir scan, ~2-5s), and the
    // user typically reaches the flash-target / emmc-backup screens a
    // few clicks into the wizard — by then the keepAlive'd cache is
    // already populated and those screens render their tables
    // immediately instead of sitting on a spinner. Errors are
    // intentionally swallowed here: if the probe fails, the
    // flash-target screen still surfaces the error via its own
    // AsyncValue.hasError branch when the user actually navigates to
    // it. .ignore() avoids "unhandled future error" reports if the
    // user closes the app before reaching the flash flow.
    ref.read(disksProvider.future).ignore();
  }

  /// Map the live router location to a `currentStep` token the
  /// WizardController persists into [WizardState]. The token is the
  /// route path with the leading slash stripped, with `/` aliased to
  /// `'welcome'` so it matches [WizardState.initial]'s default and
  /// [routeForResumeStep]'s reverse lookup.
  void _syncCurrentStep() {
    final loc = _router.routerDelegate.currentConfiguration.uri.path;
    final step = loc == '/' ? 'welcome' : loc.replaceFirst('/', '');
    ref.read(wizardControllerProvider).setCurrentStep(step);
  }

  /// Called by Flutter when the OS asks the app to exit (window
  /// close, Cmd-Q, taskkill, etc.). We use the hook to AWAIT the
  /// final wizard-state save before returning, so a snapshot taken
  /// "just before close" is durably on disk by the time the process
  /// exits — even if the event-driven `wizardStateProvider` save
  /// queued the same state moments earlier and hadn't completed.
  ///
  /// The save is best-effort: if the disk write fails we still let
  /// the exit proceed, because blocking the user's "close" intent on
  /// a flaky disk would be punitive. [WizardStateStore.save] is
  /// already coalesce-safe, so calling it here on top of the
  /// stream's pending save is a no-op when nothing changed.
  @override
  Future<AppExitResponse> didRequestAppExit() async {
    final store = ref.read(wizardStateStoreProvider);
    final controller = ref.read(wizardControllerProvider);
    final state = controller.state;
    if (store != null && isPersistableWizardState(state)) {
      try {
        await store.save(state);
      } catch (_) {
        // best-effort; never block exit on a save failure
      }
    }
    return AppExitResponse.exit;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _router.routerDelegate.removeListener(_syncCurrentStep);
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp.router(
      title: 'Deckhand',
      theme: DeckhandTheme.light(),
      darkTheme: DeckhandTheme.dark(),
      themeMode: themeMode,
      routerConfig: _router,
      builder: (context, child) => ResumeGate(
        child: child ?? const SizedBox.shrink(),
      ),
    );
  }
}
