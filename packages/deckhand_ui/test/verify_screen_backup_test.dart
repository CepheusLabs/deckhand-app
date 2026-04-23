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
        expect(
          find.text('Prune backups > 30 days old'),
          findsOneWidget,
        );
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
