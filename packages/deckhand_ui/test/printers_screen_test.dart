import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/providers.dart';
import 'package:deckhand_ui/src/screens/printers_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('PrintersScreen', () {
    testWidgets('lists every known printer and opens manage for one', (
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
      settings.recordManagedPrinter(
        ManagedPrinter.fromConnection(
          profileId: 'test-printer',
          displayName: 'Second Printer',
          host: '192.168.1.51',
          port: 2222,
          user: 'mks',
          lastSeen: DateTime.utc(2026, 5, 4, 13),
        ),
      );

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const PrintersScreen(),
          initialLocation: '/printers',
          extraOverrides: [
            deckhandSettingsProvider.overrideWithValue(settings),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Printers'), findsOneWidget);
      expect(find.text('Test Printer'), findsOneWidget);
      expect(find.text('Second Printer'), findsOneWidget);
      expect(find.textContaining('root@192.168.1.50'), findsOneWidget);
      expect(find.textContaining('mks@192.168.1.51:2222'), findsOneWidget);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Manage').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(controller.state.profileId, 'test-printer');
      expect(controller.state.sshHost, '192.168.1.51');
      expect(controller.state.sshPort, 2222);
      expect(controller.state.sshUser, 'mks');
      expect(controller.profile?.displayName, 'Test Printer');
    });

    testWidgets('forgets a known printer from the registry', (tester) async {
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
          child: const PrintersScreen(),
          initialLocation: '/printers',
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
      expect(find.text('No printers saved yet.'), findsOneWidget);
    });

    testWidgets('uses the managed printer registry provider', (tester) async {
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
          child: const PrintersScreen(),
          initialLocation: '/printers',
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

    testWidgets('filters saved printers by name, host, profile, or user', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      final registry = _MemoryManagedPrinterRegistry([
        ManagedPrinter.fromConnection(
          profileId: 'test-printer',
          displayName: 'Arco Bench',
          host: '192.168.1.50',
          port: 22,
          user: 'mks',
          lastSeen: DateTime.utc(2026, 5, 4, 14),
        ),
        ManagedPrinter.fromConnection(
          profileId: 'test-printer',
          displayName: 'Shop Printer',
          host: '192.168.1.72',
          port: 22,
          user: 'root',
          lastSeen: DateTime.utc(2026, 5, 4, 15),
        ),
      ]);

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const PrintersScreen(),
          initialLocation: '/printers',
          extraOverrides: [
            managedPrinterRegistryProvider.overrideWithValue(registry),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Arco Bench'), findsOneWidget);
      expect(find.text('Shop Printer'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '72');
      await tester.pump();

      expect(find.text('Arco Bench'), findsNothing);
      expect(find.text('Shop Printer'), findsOneWidget);
      expect(find.text('1 of 2 shown'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'missing');
      await tester.pump();

      expect(find.text('Shop Printer'), findsNothing);
      expect(find.text('No saved printers match "missing".'), findsOneWidget);
    });
  });
}

class _MemoryManagedPrinterRegistry implements ManagedPrinterRegistry {
  _MemoryManagedPrinterRegistry(List<ManagedPrinter> printers)
    : _printers = printers.toList();

  final List<ManagedPrinter> _printers;
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
  }
}
