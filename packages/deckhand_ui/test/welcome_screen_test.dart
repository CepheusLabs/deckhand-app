import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/providers.dart';
import 'package:deckhand_ui/src/screens/welcome_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('WelcomeScreen', () {
    testWidgets('NEW INSTALL panel always renders; RESUME panel hidden when no '
        'saved snapshot', (tester) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const WelcomeScreen(),
          initialLocation: '/',
        ),
      );
      await tester.pumpAndSettle();

      // The design-language eyebrow + headline pair for the left card.
      expect(find.text('NEW INSTALL'), findsOneWidget);
      expect(find.text('Set up a printer from scratch.'), findsOneWidget);
      expect(find.text('Start a new install'), findsOneWidget);
      expect(find.text('PRINTERS'), findsOneWidget);
      expect(find.text('Manage known printers.'), findsOneWidget);
      expect(
        find.widgetWithText(OutlinedButton, 'Open printer manager'),
        findsOneWidget,
      );
      expect(find.text('RECOVERY'), findsOneWidget);
      expect(find.text('Restore an eMMC backup.'), findsOneWidget);
      expect(
        find.widgetWithText(OutlinedButton, 'Restore eMMC backup'),
        findsOneWidget,
      );

      // The welcome screen keeps action choices inside the panels;
      // a duplicate footer Start button made the entry point look
      // like two competing flows.
      expect(find.text('Start'), findsNothing);

      // Without a saved snapshot the RESUME panel must NOT render.
      expect(find.text('RESUME'), findsNothing);
      expect(find.text('You have one in-progress install.'), findsNothing);

      // Settings now lives in the sidenav foot (rendered by
      // [DeckhandAppChrome]), not on this screen.
      expect(find.text('Settings'), findsNothing);
    });

    testWidgets('RESUME panel renders for a mid-wizard snapshot', (
      tester,
    ) async {
      // Pre-seed the in-memory store with a non-trivial snapshot so
      // savedWizardSnapshotProvider returns it once the future
      // resolves.
      final store = InMemoryWizardStateStore();
      await store.save(
        const WizardState(
          profileId: 'phrozen-arco',
          decisions: {'firmware': 'kalico'},
          currentStep: 'choose-path',
          flow: WizardFlow.stockKeep,
        ),
      );

      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const WelcomeScreen(),
          initialLocation: '/',
          extraOverrides: [wizardStateStoreProvider.overrideWithValue(store)],
        ),
      );
      await tester.pumpAndSettle();
      // Two extra microtask drains: the provider's Future resolves
      // a tick after pumpAndSettle reports settled, and
      // FutureProvider needs a frame to propagate the new state to
      // ref.watch consumers.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Both panels visible.
      expect(find.text('NEW INSTALL'), findsOneWidget);
      expect(find.text('RESUME'), findsOneWidget);
      expect(find.text('You have one in-progress install.'), findsOneWidget);

      // The IdTag row carries the profile, the design-language
      // S-id for the saved step, and a relative-time chip.
      expect(find.text('phrozen-arco'), findsOneWidget);
      expect(find.text('S40 · choose-path'), findsOneWidget);

      // Resume + Discard actions are present and enabled.
      expect(find.widgetWithText(FilledButton, 'Resume'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Manage'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Discard'), findsOneWidget);
    });

    testWidgets('resume panels stack without overflow in a narrow window', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(520, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final store = InMemoryWizardStateStore();
      await store.save(
        const WizardState(
          profileId: 'phrozen-arco',
          decisions: {'firmware': 'kalico'},
          currentStep: 'choose-path',
          flow: WizardFlow.stockKeep,
        ),
      );

      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const WelcomeScreen(),
          initialLocation: '/',
          extraOverrides: [wizardStateStoreProvider.overrideWithValue(store)],
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(tester.takeException(), isNull);
      expect(find.text('NEW INSTALL'), findsOneWidget);
      expect(find.text('RESUME'), findsOneWidget);
      expect(find.text('You have one in-progress install.'), findsOneWidget);
    });

    testWidgets('discard keeps resume card visible when store clear fails', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final store = _FailingClearWizardStateStore();
      await store.save(
        const WizardState(
          profileId: 'phrozen-arco',
          decisions: {},
          currentStep: 'choose-path',
          flow: WizardFlow.stockKeep,
        ),
      );

      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const WelcomeScreen(),
          initialLocation: '/',
          extraOverrides: [wizardStateStoreProvider.overrideWithValue(store)],
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final discardButton = find.widgetWithText(TextButton, 'Discard');
      await tester.ensureVisible(discardButton);
      await tester.tap(discardButton);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Discard'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('RESUME'), findsOneWidget);
      expect(find.text('You have one in-progress install.'), findsOneWidget);
      expect(find.textContaining("Deckhand couldn't discard"), findsOneWidget);
    });

    testWidgets('known printers can open manage without a resume session', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      final temp = Directory.systemTemp.createTempSync('deckhand-settings-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final settings = DeckhandSettings(path: '${temp.path}/settings.json');
      settings.recordManagedPrinter(
        ManagedPrinter.fromConnection(
          profileId: 'test-printer',
          displayName: 'Test Printer',
          host: '192.168.1.50',
          port: 22,
          user: 'root',
          lastSeen: DateTime.utc(2026, 5, 4, 12),
        ),
      );

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const WelcomeScreen(),
          initialLocation: '/',
          extraOverrides: [
            deckhandSettingsProvider.overrideWithValue(settings),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('PRINTERS'), findsOneWidget);
      expect(find.text('Manage known printers.'), findsOneWidget);
      expect(find.text('Test Printer'), findsOneWidget);
      expect(find.textContaining('192.168.1.50'), findsOneWidget);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Manage').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(controller.state.profileId, 'test-printer');
      expect(controller.state.sshHost, '192.168.1.50');
      expect(controller.profile?.displayName, 'Test Printer');
    });

    testWidgets('known printers can be forgotten from the welcome screen', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      final temp = Directory.systemTemp.createTempSync('deckhand-settings-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final settings = DeckhandSettings(path: '${temp.path}/settings.json');
      settings.recordManagedPrinter(
        ManagedPrinter.fromConnection(
          profileId: 'test-printer',
          displayName: 'Test Printer',
          host: '192.168.1.50',
          port: 22,
          user: 'root',
          lastSeen: DateTime.utc(2026, 5, 4, 12),
        ),
      );

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const WelcomeScreen(),
          initialLocation: '/',
          extraOverrides: [
            deckhandSettingsProvider.overrideWithValue(settings),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Test Printer'), findsOneWidget);

      await tester.tap(find.byTooltip('Forget printer'));
      await tester.pump();

      expect(settings.managedPrinters, isEmpty);
      expect(find.text('Test Printer'), findsNothing);
      expect(
        find.textContaining('Use the printer manager to reopen saved printers'),
        findsOneWidget,
      );
    });

    testWidgets('known printers panel uses managed printer registry provider', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      final registry = _MemoryManagedPrinterRegistry([
        ManagedPrinter.fromConnection(
          profileId: 'test-printer',
          displayName: 'Provider Printer',
          host: '192.168.1.60',
          port: 22,
          user: 'mks',
          lastSeen: DateTime.utc(2026, 5, 4, 14),
        ),
      ]);

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const WelcomeScreen(),
          initialLocation: '/',
          extraOverrides: [
            managedPrinterRegistryProvider.overrideWithValue(registry),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Provider Printer'), findsOneWidget);

      await tester.tap(find.byTooltip('Forget printer'));
      await tester.pump();

      expect(registry.saved, isTrue);
      expect(registry.listManagedPrinters(), isEmpty);
      expect(find.text('Provider Printer'), findsNothing);
    });

    testWidgets('known printers panel warns when forget cannot be saved', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      final registry = _MemoryManagedPrinterRegistry([
        ManagedPrinter.fromConnection(
          profileId: 'test-printer',
          displayName: 'Provider Printer',
          host: '192.168.1.60',
          port: 22,
          user: 'mks',
          lastSeen: DateTime.utc(2026, 5, 4, 14),
        ),
      ], failSave: true);

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const WelcomeScreen(),
          initialLocation: '/',
          extraOverrides: [
            managedPrinterRegistryProvider.overrideWithValue(registry),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Forget printer'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(registry.listManagedPrinters(), isEmpty);
      expect(find.text('Provider Printer'), findsNothing);
      expect(
        find.textContaining("Deckhand couldn't save that change"),
        findsOneWidget,
      );
    });

    testWidgets('known printers panel links to overflow printers', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      final registry = _MemoryManagedPrinterRegistry([
        for (var i = 0; i < 5; i++)
          ManagedPrinter.fromConnection(
            profileId: 'test-printer',
            displayName: 'Printer $i',
            host: '192.168.1.${50 + i}',
            port: 22,
            user: 'mks',
            lastSeen: DateTime.utc(2026, 5, 4, 14, i),
          ),
      ]);

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const WelcomeScreen(),
          initialLocation: '/',
          extraOverrides: [
            managedPrinterRegistryProvider.overrideWithValue(registry),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Printer 0'), findsOneWidget);
      expect(find.text('Printer 3'), findsOneWidget);
      expect(find.text('Printer 4'), findsNothing);
      expect(find.text('1 more printer in manager'), findsOneWidget);
    });
  });
}

class _MemoryManagedPrinterRegistry implements ManagedPrinterRegistry {
  _MemoryManagedPrinterRegistry(
    List<ManagedPrinter> printers, {
    this.failSave = false,
  }) : _printers = printers.toList();

  final List<ManagedPrinter> _printers;
  final bool failSave;
  bool saved = false;

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
    saved = true;
    if (failSave) {
      throw StateError('write settings failed on \\\\.\\PHYSICALDRIVE3');
    }
  }
}

class _FailingClearWizardStateStore extends InMemoryWizardStateStore {
  @override
  Future<void> clear() async {
    throw StateError('delete snapshot failed on \\\\.\\PHYSICALDRIVE3');
  }
}
