import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/screens/files_screen.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('FilesScreen', () {
    testWidgets(
      'partitions files into present vs already-clean using probe state',
      (tester) async {
        final controller = stubWizardController(
          profileJson: {
            'profile_id': 'test-printer',
            'profile_version': '0.1.0',
            'display_name': 'Test',
            'status': 'alpha',
            'os': <String, Object?>{},
            'ssh': {
              'default_credentials': [
                {'user': 'root', 'password': 'root'},
              ],
            },
            'flows': {
              'stock_keep': {
                'enabled': true,
                'steps': <Map<String, Object?>>[],
              },
            },
            'stock_os': {
              'files': [
                {
                  'id': 'frpc_bin',
                  'display_name': 'frpc binary',
                  'paths': ['/usr/local/bin/frpc'],
                  'default_action': 'delete',
                },
                {
                  'id': 'stock_notes',
                  'display_name': 'Dated txt notes',
                  'paths': ['/home/mks/notes.txt'],
                  'default_action': 'delete',
                },
              ],
            },
          },
        );
        await controller.loadProfile('test-printer');
        controller.setFlow(WizardFlow.stockKeep);
        // Inject a canned probe result: frpc_bin present, stock_notes
        // already removed. probedAt non-null so the UI trusts the
        // partition instead of showing its loading banner.
        controller.printerStateForTesting = PrinterState(
          services: const {},
          files: const {'frpc_bin': true, 'stock_notes': false},
          paths: const {},
          stackInstalls: const {},
          screenInstalls: const {},
          python311Installed: false,
          probedAt: DateTime.now(),
        );

        await tester.pumpWidget(
          testHarness(
            controller: controller,
            child: const FilesScreen(),
            initialLocation: '/files',
          ),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('frpc binary'), findsOneWidget);
        expect(find.textContaining('Dated txt notes'), findsOneWidget);
        expect(find.textContaining('Already clean'), findsOneWidget);
      },
    );

    testWidgets('probe-loading banner visible until the probe reports', (
      tester,
    ) async {
      final controller = stubWizardController(
        profileJson: {
          'profile_id': 'test-printer',
          'profile_version': '0.1.0',
          'display_name': 'Test',
          'status': 'alpha',
          'ssh': {
            'default_credentials': [
              {'user': 'root', 'password': 'root'},
            ],
          },
          'flows': {
            'stock_keep': {'enabled': true, 'steps': <Map<String, Object?>>[]},
          },
          'stock_os': {
            'files': [
              {
                'id': 'x',
                'display_name': 'X',
                'paths': ['/x'],
              },
            ],
          },
        },
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const FilesScreen(),
          initialLocation: '/files',
        ),
      );
      // The loading banner has a CircularProgressIndicator that never
      // settles; pump a few frames instead of pumpAndSettle.
      await tester.pump();
      // probedAt == null -> banner visible.
      expect(find.textContaining('Probing this printer'), findsOneWidget);
    });

    testWidgets('malformed wizard helper metadata is ignored', (tester) async {
      final controller = stubWizardController(
        profileJson: {
          'profile_id': 'test-printer',
          'profile_version': '0.1.0',
          'display_name': 'Test',
          'status': 'alpha',
          'ssh': {
            'default_credentials': [
              {'user': 'root', 'password': 'root'},
            ],
          },
          'flows': {
            'stock_keep': {'enabled': true, 'steps': <Map<String, Object?>>[]},
          },
          'stock_os': {
            'files': [
              {
                'id': 'stock_notes',
                'display_name': 'Dated txt notes',
                'paths': ['/home/mks/notes.txt'],
                'wizard': ['not a map'],
              },
            ],
          },
        },
      );
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);
      controller.printerStateForTesting = PrinterState(
        services: const {},
        files: const {'stock_notes': true},
        paths: const {},
        stackInstalls: const {},
        screenInstalls: const {},
        python311Installed: false,
        probedAt: DateTime.now(),
      );

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const FilesScreen(),
          initialLocation: '/files',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Dated txt notes'), findsOneWidget);
    });
  });
}
