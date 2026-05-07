import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// Apply any window geometry persisted by a prior session. No-ops on
/// platforms where window_manager isn't useful (Android, iOS, web).
/// Called BEFORE `runApp` so the user never sees a flash of the
/// default size.
Future<void> applyPersistedWindowGeometry(DeckhandSettings settings) async {
  if (!_isDesktop) return;
  final saved = validRestoredWindowGeometry(
    settings.windowGeometry,
    visibleDisplayBounds: _primaryDisplayBounds(),
  );
  // Sensible defaults if there's nothing on disk yet — match the
  // figma mocks rather than the platform default.
  const defaultSize = Size(1100, 760);
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      size: saved == null ? defaultSize : Size(saved.width, saved.height),
      minimumSize: const Size(900, 600),
      title: 'Deckhand',
    ),
    () async {
      if (saved?.x != null && saved?.y != null) {
        await windowManager.setPosition(Offset(saved!.x!, saved.y!));
      } else {
        await windowManager.center();
      }
      await windowManager.show();
      await windowManager.focus();
    },
  );
}

bool get _isDesktop =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// Returns saved geometry only when its top-left corner and minimum
/// visible area still land on the current primary display. This avoids
/// restoring to coordinates from an unplugged monitor.
@visibleForTesting
WindowGeometry? validRestoredWindowGeometry(
  WindowGeometry? saved, {
  required Rect visibleDisplayBounds,
}) {
  if (saved == null) return null;
  if (saved.width < 900 || saved.height < 600) return null;
  final x = saved.x;
  final y = saved.y;
  if (x == null || y == null) {
    return WindowGeometry(width: saved.width, height: saved.height);
  }
  final window = Rect.fromLTWH(x, y, saved.width, saved.height);
  final visible = window.intersect(visibleDisplayBounds);
  if (visible.isEmpty) return null;
  const minVisible = Size(160, 120);
  if (visible.width < minVisible.width || visible.height < minVisible.height) {
    return null;
  }
  return saved;
}

Rect _primaryDisplayBounds() {
  final dispatcher =
      WidgetsFlutterBinding.ensureInitialized().platformDispatcher;
  ui.Display? display;
  final views = dispatcher.views;
  if (views.isNotEmpty) {
    display = views.first.display;
  }
  if (display == null) {
    return const Rect.fromLTWH(0, 0, 1920, 1080);
  }
  final ratio = display.devicePixelRatio;
  return Rect.fromLTWH(
    0,
    0,
    display.size.width / ratio,
    display.size.height / ratio,
  );
}

/// Mounts a [WindowListener] that persists size + position changes
/// to [DeckhandSettings] on every move/resize. The persisting writes
/// are debounced to a single trailing save so dragging the window
/// across the screen doesn't pound `settings.json`.
class WindowGeometryObserver extends StatefulWidget {
  const WindowGeometryObserver({
    super.key,
    required this.settings,
    required this.child,
    this.onError,
    this.enabled = true,
  });

  final DeckhandSettings settings;
  final Widget child;

  /// When false, the observer renders its child but registers no
  /// window listener and persists nothing. Production passes the
  /// default `true`; widget tests pass `false` so they don't hang
  /// on a window_manager platform channel that has no native handler.
  final bool enabled;

  /// Receives any geometry-persistence failure. Wired to the same log
  /// sink as [WizardStateStore.errorSink] in main.dart so a flaky FS
  /// surfaces in `<logsDir>/wizard_state_errors.log` instead of being
  /// silently dropped.
  final void Function(Object error, StackTrace stackTrace)? onError;

  @override
  State<WindowGeometryObserver> createState() => _WindowGeometryObserverState();
}

class _WindowGeometryObserverState extends State<WindowGeometryObserver>
    with WindowListener {
  Timer? _debounce;
  bool _listenerAttached = false;

  @override
  void initState() {
    super.initState();
    // Listener registration goes through the window_manager platform
    // channel. In a Flutter widget test the channel isn't wired up
    // and we'd hang on the response — the test passes
    // `enabled: false` to opt out cleanly. Production (real desktop
    // binding) attaches normally.
    if (widget.enabled && _isDesktop) {
      try {
        windowManager.addListener(this);
        _listenerAttached = true;
      } on Object catch (e, st) {
        // The plugin may not be initialised yet (rare — we call
        // ensureInitialized() in main.dart). Surface the failure
        // through the same sink the actual save path uses.
        widget.onError?.call(e, st);
      }
    }
  }

  @override
  void dispose() {
    if (_listenerAttached) {
      try {
        windowManager.removeListener(this);
      } on Object {
        // Removing a listener after the binding has already torn
        // down throws on some platforms; nothing actionable here.
      }
    }
    _debounce?.cancel();
    super.dispose();
  }

  @override
  void onWindowResize() => _scheduleSave();

  @override
  void onWindowMove() => _scheduleSave();

  @override
  void onWindowClose() {
    // Final flush so the very last drag/resize before the user closes
    // is persisted. The debounce timer isn't guaranteed to fire on
    // shutdown otherwise.
    _flushNow();
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _flushNow);
  }

  Future<void> _flushNow() async {
    if (!_isDesktop) return;
    try {
      final size = await windowManager.getSize();
      final pos = await windowManager.getPosition();
      widget.settings.windowGeometry = WindowGeometry(
        width: size.width,
        height: size.height,
        x: pos.dx,
        y: pos.dy,
      );
      await widget.settings.save();
    } on Object catch (e, st) {
      // Geometry persistence is QoL; never block the app on it. Route
      // failures to the same error log used by the wizard-state store
      // so a flaky FS / locked file surfaces somewhere instead of
      // disappearing.
      widget.onError?.call(e, st);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
