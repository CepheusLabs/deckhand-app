import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/screens/verify_screen.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('VerifyScreen backup UI', () {
    testWidgets(
      'renders a restore offer + metadata per discovered backup',
      (tester) async {
        final controller = stubWizardController(
          profileJson: testProfileJson(),
        );
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
        expect(
          find.textContaining('profile test-printer'),
          findsOneWidget,
        );
        expect(find.text('Restore'), findsOneWidget);
        expect(find.text('Preview'), findsOneWidget);
        expect(find.text('Delete'), findsOneWidget);
        // New configurable prune control: dropdown + keep-latest
        // checkbox + "Prune now" trigger.
        expect(
          find.textContaining('Prune backups older than'),
          findsOneWidget,
        );
        expect(find.text('Prune now'), findsOneWidget);
        expect(
          find.textContaining('Keep the newest snapshot'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'legacy backups (no sidecar metadata) render in their own section',
      (tester) async {
        final controller = stubWizardController(
          profileJson: testProfileJson(),
        );
        await controller.loadProfile('test-printer');
        controller.setFlow(WizardFlow.stockKeep);
        controller.printerStateForTesting = PrinterState(
          services: const {},
          files: const {},
          paths: const {},
          stackInstalls: const {},
          screenInstalls: const {},
          python311Installed: false,
          deckhandBackups: const [
            DeckhandBackup(
              originalPath: '/etc/fstab',
              backupPath: '/etc/fstab.deckhand-pre-1776910000000',
              // No profileId - this is a legacy backup.
            ),
          ],
          probedAt: null,
        );
        // Use force probedAt so the screen thinks probe finished.
        controller.printerStateForTesting = PrinterState(
          services: const {},
          files: const {},
          paths: const {},
          stackInstalls: const {},
          screenInstalls: const {},
          python311Installed: false,
          deckhandBackups: const [
            DeckhandBackup(
              originalPath: '/etc/fstab',
              backupPath: '/etc/fstab.deckhand-pre-1776910000000',
            ),
          ],
          probedAt: null,
        );
        await tester.pumpWidget(testHarness(
          controller: controller,
          child: const VerifyScreen(),
          initialLocation: '/verify',
        ));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Legacy backups without profile metadata'),
          findsOneWidget,
        );
        expect(find.text('/etc/fstab'), findsOneWidget);
      },
    );

    testWidgets(
      'Delete button opens a confirm dialog and does nothing if cancelled',
      (tester) async {
        final controller = stubWizardController(
          profileJson: testProfileJson(),
        );
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
        await tester.pumpWidget(testHarness(
          controller: controller,
          child: const VerifyScreen(),
          initialLocation: '/verify',
        ));
        await tester.pumpAndSettle();

        // Click Delete: confirm dialog pops up.
        await tester.tap(find.text('Delete').first);
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Delete this backup?'),
          findsOneWidget,
        );
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
      'foreign-profile backups render without a Restore button',
      (tester) async {
        final controller = stubWizardController(
          profileJson: testProfileJson(),
        );
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
      },
    );
  });
}
