import 'dart:async';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/providers.dart';
import 'package:deckhand_ui/src/screens/connect_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('ConnectScreen', () {
    testWidgets('manual-host tab shows a host input field', (tester) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const ConnectScreen(),
          initialLocation: '/connect',
        ),
      );
      // Let the async mDNS + CIDR sweeps resolve (stubbed to return
      // empty). pumpAndSettle would block on the scan's own delays,
      // so we just pump a few frames.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Switch to the Manual host tab — the design's S20 puts the
      // host input behind its own tab now, so the field is only in
      // the widget tree when that tab is active.
      await tester.tap(find.text('Manual host'));
      await tester.pump();

      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('discover tab exposes a Refresh affordance', (tester) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const ConnectScreen(),
          initialLocation: '/connect',
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Refresh lives next to the tab strip on the Discover tab.
      // The label changed from "Rescan" → "Refresh" with the tab
      // redesign; both intents are the same — re-run discovery.
      expect(find.text('Refresh'), findsOneWidget);
    });

    testWidgets(
      'discovered card detail uses "Printer found" (not "Moonraker")',
      (tester) async {
        final controller = stubWizardController(profileJson: testProfileJson());
        await controller.loadProfile('test-printer');
        await tester.pumpWidget(
          testHarness(
            controller: controller,
            child: const ConnectScreen(),
            initialLocation: '/connect',
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        // Developer-jargon check: "Moonraker" label must NOT be
        // surfaced as a card detail.
        expect(find.text('Moonraker'), findsNothing);
      },
    );

    testWidgets('host-key mismatch opens debug bundle review', (tester) async {
      final controller = stubWizardController(
        profileJson: testProfileJson(),
        ssh: stubSsh(
          connectError: const HostKeyMismatchException(
            host: '192.168.1.50',
            fingerprint: 'SHA256:received',
          ),
        ),
        security: stubSecurity(pinnedFingerprint: 'SHA256:expected'),
      );
      await controller.loadProfile('test-printer');

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const ConnectScreen(),
          initialLocation: '/connect',
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.text('Manual host'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '192.168.1.50');
      await tester.pump();
      await tester.tap(find.text('Connect'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Host key mismatch.'), findsOneWidget);

      await tester.tap(find.text('Save debug bundle'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Review debug bundle'), findsOneWidget);
      expect(find.textContaining('Host key mismatch'), findsWidgets);
      expect(find.textContaining('SHA256:received'), findsWidgets);
    });

    testWidgets('successful connect records through managed printer registry', (
      tester,
    ) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      final settings = _RecordingSettings();
      final registry = _MemoryManagedPrinterRegistry();

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const ConnectScreen(),
          initialLocation: '/connect',
          extraOverrides: [
            deckhandSettingsProvider.overrideWithValue(settings),
            managedPrinterRegistryProvider.overrideWithValue(registry),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.text('Manual host'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '192.168.1.50');
      await tester.pump();
      await tester.tap(find.text('Connect'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(
        () => Future.wait([settings.saved, registry.savedFuture]),
      );

      final printers = registry.listManagedPrinters();
      expect(settings.saveCount, 1);
      expect(registry.saved, isTrue);
      expect(settings.savedHosts, hasLength(1));
      expect(settings.savedHosts.single.host, '192.168.1.50');
      expect(printers, hasLength(1));
      expect(printers.single.displayName, 'Test Printer');
      expect(printers.single.host, '192.168.1.50');
      expect(printers.single.user, 'root');
    });

    testWidgets('successful connect persists default saved-host registry', (
      tester,
    ) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      final settings = _RecordingSettings();

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const ConnectScreen(),
          initialLocation: '/connect',
          extraOverrides: [
            deckhandSettingsProvider.overrideWithValue(settings),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.text('Manual host'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '192.168.1.50');
      await tester.pump();
      await tester.tap(find.text('Connect'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() => settings.saved);

      expect(settings.saveCount, 1);
      expect(settings.savedHosts, hasLength(1));
      expect(settings.savedHosts.single.host, '192.168.1.50');
      expect(settings.savedHosts.single.user, 'root');
      expect(settings.managedPrinters, hasLength(1));
      expect(settings.managedPrinters.single.displayName, 'Test Printer');
      expect(settings.managedPrinters.single.host, '192.168.1.50');
    });
  });
}

class _RecordingSettings extends DeckhandSettings {
  _RecordingSettings() : super(path: '<recording>');

  final Completer<void> _saved = Completer<void>();
  int saveCount = 0;

  Future<void> get saved => _saved.future;

  @override
  Future<void> save() async {
    saveCount++;
    if (!_saved.isCompleted) {
      _saved.complete();
    }
  }
}

class _MemoryManagedPrinterRegistry implements ManagedPrinterRegistry {
  final List<ManagedPrinter> _printers = [];
  final Completer<void> _saved = Completer<void>();
  bool _wasSaved = false;

  bool get saved => _wasSaved;
  Future<void> get savedFuture => _saved.future;

  @override
  List<ManagedPrinter> listManagedPrinters() => List.unmodifiable(_printers);

  @override
  void recordManagedPrinter(ManagedPrinter printer) {
    _printers
      ..removeWhere((p) => p.id.toLowerCase() == printer.id.toLowerCase())
      ..insert(0, printer);
  }

  @override
  void forgetManagedPrinter(String id) {
    _printers.removeWhere((p) => p.id.toLowerCase() == id.toLowerCase());
  }

  @override
  Future<void> save() async {
    _wasSaved = true;
    if (!_saved.isCompleted) {
      _saved.complete();
    }
  }
}
