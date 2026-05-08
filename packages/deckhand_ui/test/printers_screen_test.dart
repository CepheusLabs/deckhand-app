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

      expect(find.text('Printers.'), findsOneWidget);
      expect(find.text('Test Printer'), findsOneWidget);
      expect(find.text('Second Printer'), findsOneWidget);
      expect(find.textContaining('root@192.168.1.50'), findsOneWidget);
      expect(find.textContaining('mks@192.168.1.51:2222'), findsOneWidget);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Manage').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(controller.state.profileId, 'test-printer');
      expect(controller.state.sshHost, '192.168.1.51');
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
  });
}
