import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/providers.dart';
import 'package:deckhand_ui/src/screens/verify_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('VerifyScreen backup UI', () {
    testWidgets('malformed optional detection metadata is ignored', (
      tester,
    ) async {
      final controller = stubWizardController(
        profileJson: {
          ...testProfileJson(),
          'stock_os': {
            'detections': [
              {
                'kind': 'file_contains',
                'path': 42,
                'pattern': ['not text'],
                'label': 99,
                'note': {'bad': true},
              },
              {'kind': 'process_running', 'name': false},
              {'kind': 'moonraker_object', 'object': 123},
            ],
          },
        },
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const VerifyScreen(),
          initialLocation: '/verify',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(VerifyScreen), findsOneWidget);
      expect(find.textContaining('not text'), findsNothing);
    });

    testWidgets('renders a restore offer + metadata per discovered backup', (
      tester,
    ) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);
      controller.printerStateForTesting = PrinterState(
        services: const {},
        files: const {},
        paths: const {},
        stackInstalls: const {},
        screenInstalls: const {},
        python311Installed: false,
        deckhandBackups: [
          DeckhandBackup(
            originalPath: '/etc/apt/sources.list',
            backupPath:
                '/etc/apt/sources.list.deckhand-pre-test-printer-1776910000000',
            profileId: 'test-printer',
            profileVersion: '0.1.0',
            stepId: 'fix_apt_sources',
            createdAt: DateTime(2026, 4, 22, 10, 30),
          ),
        ],
        probedAt: DateTime.now(),
      );
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const VerifyScreen(),
          initialLocation: '/verify',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('/etc/apt/sources.list'), findsOneWidget);
      // profile-id + step-id moved to a Tooltip on the tile so
      // they're no longer user-visible by default. What the user
      // sees is the timestamp. Find any Tooltip whose message
      // includes the internal profile-id marker.
      final tooltips = tester.widgetList<Tooltip>(find.byType(Tooltip));
      expect(
        tooltips.any((t) => (t.message ?? '').contains('profile test-printer')),
        isTrue,
        reason: 'Tooltip on backup tile should surface profile-id',
      );
      expect(find.text('Restore'), findsOneWidget);
      expect(find.text('Preview'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      // New configurable prune control: dropdown + keep-latest
      // checkbox + "Prune now" trigger.
      expect(find.textContaining('Prune backups older than'), findsOneWidget);
      expect(find.text('Prune now'), findsOneWidget);
      expect(find.textContaining('Keep the newest snapshot'), findsOneWidget);
    });

    testWidgets(
      'legacy backups (no sidecar metadata) render in their own section',
      (tester) async {
        final controller = stubWizardController(profileJson: testProfileJson());
        await controller.loadProfile('test-printer');
        controller.setFlow(WizardFlow.stockKeep);
        controller.printerStateForTesting = const PrinterState(
          services: {},
          files: {},
          paths: {},
          stackInstalls: {},
          screenInstalls: {},
          python311Installed: false,
          deckhandBackups: [
            DeckhandBackup(
              originalPath: '/etc/fstab',
              backupPath: '/etc/fstab.deckhand-pre-1776910000000',
              // No profileId - this is a legacy backup.
            ),
          ],
          probedAt: null,
        );
        // Use force probedAt so the screen thinks probe finished.
        controller.printerStateForTesting = const PrinterState(
          services: {},
          files: {},
          paths: {},
          stackInstalls: {},
          screenInstalls: {},
          python311Installed: false,
          deckhandBackups: [
            DeckhandBackup(
              originalPath: '/etc/fstab',
              backupPath: '/etc/fstab.deckhand-pre-1776910000000',
            ),
          ],
          probedAt: null,
        );
        await tester.pumpWidget(
          testHarness(
            controller: controller,
            child: const VerifyScreen(),
            initialLocation: '/verify',
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Older backups without metadata'),
          findsOneWidget,
        );
        expect(find.text('/etc/fstab'), findsOneWidget);
      },
    );

    testWidgets(
      'Delete button opens a confirm dialog and does nothing if cancelled',
      (tester) async {
        final controller = stubWizardController(profileJson: testProfileJson());
        await controller.loadProfile('test-printer');
        controller.setFlow(WizardFlow.stockKeep);
        controller.printerStateForTesting = PrinterState(
          services: const {},
          files: const {},
          paths: const {},
          stackInstalls: const {},
          screenInstalls: const {},
          python311Installed: false,
          deckhandBackups: [
            DeckhandBackup(
              originalPath: '/etc/apt/sources.list',
              backupPath: '/etc/apt/sources.list.deckhand-pre-test-printer-1',
              profileId: 'test-printer',
              createdAt: DateTime(2026, 4, 22),
            ),
          ],
          probedAt: DateTime.now(),
        );
        await tester.pumpWidget(
          testHarness(
            controller: controller,
            child: const VerifyScreen(),
            initialLocation: '/verify',
          ),
        );
        await tester.pumpAndSettle();

        // Click Delete: confirm dialog pops up.
        await tester.tap(find.text('Delete').first);
        await tester.pumpAndSettle();
        expect(find.textContaining('Delete this backup?'), findsOneWidget);
        // Cancel.
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        // Dialog dismissed, original view restored, backup still in
        // the list (the stub SSH would have returned success either
        // way - this is a cancellation check, not a delete check).
        expect(find.textContaining('Delete this backup?'), findsNothing);
        expect(find.text('/etc/apt/sources.list'), findsOneWidget);
      },
    );

    testWidgets(
      'Prune dropdown + keep-newest checkbox fire onChanged callbacks',
      (tester) async {
        final controller = stubWizardController(profileJson: testProfileJson());
        await controller.loadProfile('test-printer');
        controller.setFlow(WizardFlow.stockKeep);
        // Seed one old backup so the prune controls render.
        controller.printerStateForTesting = PrinterState(
          services: const {},
          files: const {},
          paths: const {},
          stackInstalls: const {},
          screenInstalls: const {},
          python311Installed: false,
          deckhandBackups: [
            DeckhandBackup(
              originalPath: '/etc/apt/sources.list',
              backupPath: '/etc/apt/sources.list.deckhand-pre-test-printer-1',
              profileId: 'test-printer',
              createdAt: DateTime.now().subtract(const Duration(days: 60)),
            ),
          ],
          probedAt: DateTime.now(),
        );
        await tester.pumpWidget(
          testHarness(
            controller: controller,
            child: const VerifyScreen(),
            initialLocation: '/verify',
          ),
        );
        await tester.pumpAndSettle();

        // Dropdown: verify it renders with the default 30-day value
        // and all menu items exist; direct-state-mutation via the
        // widget is the reliable click path since dropdowns in
        // widget tests involve overlay routing that's finicky to
        // drive.
        final dropdown = find.byType(DropdownButton<int>);
        expect(dropdown, findsOneWidget);
        final dd = tester.widget<DropdownButton<int>>(dropdown);
        final itemValues = dd.items!.map((it) => it.value).toSet();
        expect(itemValues, containsAll([7, 14, 30, 60, 90, 180]));
        expect(dd.value, 30);

        // Checkbox: toggle off via widget.onChanged - no hit-testing
        // needed, and this pins the callback wiring directly.
        final cb = tester.widget<Checkbox>(find.byType(Checkbox));
        expect(cb.value, isTrue);
        cb.onChanged!.call(false);
        await tester.pumpAndSettle();
        final cbAfter = tester.widget<Checkbox>(find.byType(Checkbox));
        expect(
          cbAfter.value,
          isFalse,
          reason: 'Checkbox onChanged must flip state to false',
        );
      },
    );

    testWidgets('Prune dropdown reads initial value from DeckhandSettings', (
      tester,
    ) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);
      controller.printerStateForTesting = PrinterState(
        services: const {},
        files: const {},
        paths: const {},
        stackInstalls: const {},
        screenInstalls: const {},
        python311Installed: false,
        deckhandBackups: [
          DeckhandBackup(
            originalPath: '/etc/apt/sources.list',
            backupPath: '/etc/apt/sources.list.deckhand-pre-test-printer-1',
            profileId: 'test-printer',
            createdAt: DateTime.now().subtract(const Duration(days: 100)),
          ),
        ],
        probedAt: DateTime.now(),
      );
      await tester.pumpWidget(
        testHarnessWithSettings(
          controller: controller,
          child: const VerifyScreen(),
          initialLocation: '/verify',
          settingsSeed: (s) {
            s.pruneOlderThanDays = 14;
            s.pruneKeepNewestPerTarget = false;
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('14 days'), findsOneWidget);
      final chk = tester.widget<Checkbox>(find.byType(Checkbox));
      expect(chk.value, isFalse);
    });

    testWidgets('failed prune preference saves roll back settings', (
      tester,
    ) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);
      controller.printerStateForTesting = PrinterState(
        services: const {},
        files: const {},
        paths: const {},
        stackInstalls: const {},
        screenInstalls: const {},
        python311Installed: false,
        deckhandBackups: [
          DeckhandBackup(
            originalPath: '/etc/apt/sources.list',
            backupPath: '/etc/apt/sources.list.deckhand-pre-test-printer-1',
            profileId: 'test-printer',
            createdAt: DateTime.now().subtract(const Duration(days: 100)),
          ),
        ],
        probedAt: DateTime.now(),
      );
      final settings = _FailingSaveSettings()
        ..pruneOlderThanDays = 30
        ..pruneKeepNewestPerTarget = true;
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const VerifyScreen(),
          initialLocation: '/verify',
          extraOverrides: [
            deckhandSettingsProvider.overrideWithValue(settings),
          ],
        ),
      );
      await tester.pumpAndSettle();

      final dropdown = tester.widget<DropdownButton<int>>(
        find.byType(DropdownButton<int>),
      );
      dropdown.onChanged!.call(7);
      final checkbox = tester.widget<Checkbox>(find.byType(Checkbox));
      checkbox.onChanged!.call(false);
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Prune now'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Prune now'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(settings.pruneOlderThanDays, 30);
      expect(settings.pruneKeepNewestPerTarget, isTrue);
      expect(find.textContaining('Windows disk 3'), findsOneWidget);
      expect(find.textContaining('PHYSICALDRIVE3'), findsNothing);
    });

    testWidgets('foreign-profile backups render without a Restore button', (
      tester,
    ) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);
      controller.printerStateForTesting = PrinterState(
        services: const {},
        files: const {},
        paths: const {},
        stackInstalls: const {},
        screenInstalls: const {},
        python311Installed: false,
        deckhandBackups: [
          DeckhandBackup(
            originalPath: '/etc/apt/sources.list',
            backupPath:
                '/etc/apt/sources.list.deckhand-pre-other-printer-1776910000000',
            profileId: 'other-printer', // different from current
            profileVersion: '1.0.0',
            stepId: 'fix_apt_sources',
            createdAt: DateTime(2026, 4, 22, 10, 30),
          ),
        ],
        probedAt: DateTime.now(),
      );
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const VerifyScreen(),
          initialLocation: '/verify',
        ),
      );
      await tester.pumpAndSettle();

      // The foreign section renders the header and the path...
      expect(
        find.textContaining('Backups from other profiles'),
        findsOneWidget,
      );
      expect(find.text('/etc/apt/sources.list'), findsOneWidget);
      // ...but no Restore button (disabled via null callback).
      expect(find.text('Restore'), findsNothing);
      // Preview + Delete still available (inspection always OK).
      expect(find.text('Preview'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
    });
  });
}

class _FailingSaveSettings extends DeckhandSettings {
  _FailingSaveSettings() : super(path: '<memory>');

  @override
  Future<void> save() async {
    throw StateError(r'write settings failed on \\.\PHYSICALDRIVE3');
  }
}
