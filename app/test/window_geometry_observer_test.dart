import 'package:deckhand/window_geometry_observer.dart';
import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Widget-level test for [WindowGeometryObserver]'s widget plumbing.
///
/// The platform-channel side (real `windowManager` listener
/// registration + `setSize`/`setPosition` calls) requires a real
/// desktop binding and is exercised by the manual-QA pass documented
/// in docs/RELEASING.md. Settings round-trip is covered separately
/// in `packages/deckhand_core/test/window_geometry_test.dart`; this
/// file pins ONLY the widget contract.
///
/// Uses in-memory `DeckhandSettings` (no `await load(...)`) because
/// real `File` I/O inside a `testWidgets` body deadlocks the
/// FakeAsync zone. The pure-Dart-only path runs synchronously.
void main() {
  test('validRestoredWindowGeometry rejects off-display positions', () {
    final restored = validRestoredWindowGeometry(
      const WindowGeometry(width: 1100, height: 760, x: 4000, y: 200),
      visibleDisplayBounds: const Rect.fromLTWH(0, 0, 1920, 1080),
    );
    expect(restored, isNull);
  });

  test('validRestoredWindowGeometry keeps visible saved geometry', () {
    final saved = const WindowGeometry(width: 1100, height: 760, x: 100, y: 80);
    final restored = validRestoredWindowGeometry(
      saved,
      visibleDisplayBounds: const Rect.fromLTWH(0, 0, 1920, 1080),
    );
    expect(restored, same(saved));
  });

  testWidgets('renders its child even when disabled', (tester) async {
    final settings = DeckhandSettings(path: '<memory>');
    await tester.pumpWidget(
      MaterialApp(
        home: WindowGeometryObserver(
          settings: settings,
          enabled: false,
          child: const Scaffold(body: Text('child')),
        ),
      ),
    );
    expect(find.text('child'), findsOneWidget);
  });

  testWidgets('disabled observer does NOT register a listener', (tester) async {
    // We can't directly assert that addListener wasn't called (the
    // window_manager API doesn't expose the listener count) — but
    // disabling the observer in a test environment without a real
    // platform binding succeeds silently. If the gate ever
    // regressed (e.g. a refactor dropped the `enabled` check), this
    // test would hang waiting for the platform channel response.
    final settings = DeckhandSettings(path: '<memory>');
    await tester.pumpWidget(
      MaterialApp(
        home: WindowGeometryObserver(
          settings: settings,
          enabled: false,
          child: const Scaffold(body: Text('ok')),
        ),
      ),
    );
    // Pumping a few extra frames flushes any postFrameCallbacks the
    // observer might have scheduled. With `enabled: false` we expect
    // none — and the test must complete quickly, not time out.
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('ok'), findsOneWidget);
  });
}
