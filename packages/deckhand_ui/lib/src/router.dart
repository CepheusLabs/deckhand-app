import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'screens/choose_os_screen.dart';
import 'screens/choose_path_screen.dart';
import 'screens/connect_screen.dart';
import 'screens/done_screen.dart';
import 'screens/files_screen.dart';
import 'screens/firmware_screen.dart';
import 'screens/first_boot_screen.dart';
import 'screens/first_boot_setup_screen.dart';
import 'screens/flash_confirm_screen.dart';
import 'screens/flash_target_screen.dart';
import 'screens/hardening_screen.dart';
import 'screens/kiauh_screen.dart';
import 'screens/manage_screen.dart';
import 'screens/pick_printer_screen.dart';
import 'screens/printers_screen.dart';
import 'screens/progress_screen.dart';
import 'screens/review_screen.dart';
import 'screens/screen_choice_screen.dart';
import 'screens/services_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/emmc_backup_screen.dart';
import 'screens/snapshot_screen.dart';
import 'screens/verify_screen.dart';
import 'screens/webui_screen.dart';
import 'screens/welcome_screen.dart';
import 'widgets/deckhand_app_chrome.dart';

/// Wraps [builder] output in a [CustomTransitionPage] that cross-fades.
/// The default go_router transition on Windows is the Material
/// slide-from-right, which feels abrupt for a wizard. A short fade
/// (180 ms) keeps each step visually adjacent instead.
CustomTransitionPage<T> _fadePage<T>(Widget child, {LocalKey? key}) {
  return CustomTransitionPage<T>(
    key: key,
    child: child,
    transitionDuration: const Duration(milliseconds: 180),
    reverseTransitionDuration: const Duration(milliseconds: 120),
    transitionsBuilder: (context, animation, secondary, child) {
      return FadeTransition(
        opacity: CurvedAnimation(
          parent: animation,
          curve: Curves.easeOut,
          reverseCurve: Curves.easeIn,
        ),
        child: child,
      );
    },
  );
}

GoRoute _fade(String path, Widget Function() child) => GoRoute(
  path: path,
  pageBuilder: (context, state) => _fadePage(child(), key: state.pageKey),
);

GoRouter buildDeckhandRouter() => GoRouter(
  initialLocation: '/',
  routes: [
    // Wrap every wizard route in a [ShellRoute] so the
    // [DeckhandAppChrome] (titlebar + sidenav + footbar) renders
    // inside a route subtree. Going through `MaterialApp.router`'s
    // global `builder` was wrong — GoRouterState.of(context) is only
    // valid below a RouteBase.builder, and the chrome reaches for
    // GoRouterState to compute the current S-ID.
    ShellRoute(
      builder: (context, state, child) => DeckhandAppChrome(child: child),
      routes: [
        _fade('/', () => const WelcomeScreen()),
        _fade('/printers', () => const PrintersScreen()),
        _fade('/pick-printer', () => const PickPrinterScreen()),
        _fade('/connect', () => const ConnectScreen()),
        _fade('/verify', () => const VerifyScreen()),
        _fade('/choose-path', () => const ChoosePathScreen()),

        // Flow A (stock keep)
        _fade('/firmware', () => const FirmwareScreen()),
        _fade('/webui', () => const WebuiScreen()),
        _fade('/kiauh', () => const KiauhScreen()),
        _fade('/screen-choice', () => const ScreenChoiceScreen()),
        _fade('/services', () => const ServicesScreen()),
        _fade('/files', () => const FilesScreen()),
        _fade('/snapshot', () => const SnapshotScreen()),
        _fade('/emmc-backup', () => const EmmcBackupScreen()),
        _fade('/hardening', () => const HardeningScreen()),

        // Flow B (fresh flash)
        _fade('/flash-target', () => const FlashTargetScreen()),
        _fade('/choose-os', () => const ChooseOsScreen()),
        _fade('/flash-confirm', () => const FlashConfirmScreen()),
        // `/flash-progress` is retired; the unified `/progress` screen
        // now runs the whole fresh_flash pipeline (download, write,
        // verify, wait_for_ssh) via WizardController.startExecution.
        // Redirect any stale links.
        GoRoute(path: '/flash-progress', redirect: (_, _) => '/progress'),
        _fade('/first-boot', () => const FirstBootScreen()),
        _fade('/first-boot-setup', () => const FirstBootSetupScreen()),

        // Shared tail
        _fade('/review', () => const ReviewScreen()),
        _fade('/progress', () => const ProgressScreen()),
        _fade('/done', () => const DoneScreen()),
        _fade('/manage', () => const ManageScreen()),
        _fade(
          '/manage-emmc-backup',
          () => const EmmcBackupScreen(returnRoute: '/manage'),
        ),
        _fade('/emmc-restore', () => const EmmcRestoreScreen()),
        _fade('/settings', () => const SettingsScreen()),
      ],
    ),
  ],
);
