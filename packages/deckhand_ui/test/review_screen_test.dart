import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/screens/review_screen.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('ReviewScreen pre-run preview', () {
    Future<WizardController> buildController({
      required List<Map<String, dynamic>> steps,
      Map<String, Object> decisions = const {},
      Map<String, dynamic>? extraProfile,
    }) async {
      final profileJson = {
        ...testProfileJson(),
        if (extraProfile != null) ...extraProfile,
        'flows': {
          'stock_keep': {'enabled': true, 'steps': steps},
        },
      };
      final controller = stubWizardController(profileJson: profileJson);
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);
      for (final e in decisions.entries) {
        await controller.setDecision(e.key, e.value);
      }
      return controller;
    }

    testWidgets('renders write_file target paths', (tester) async {
      final controller = await buildController(
        steps: [
          {
            'id': 'apt',
            'kind': 'write_file',
            'target': '/etc/apt/sources.list',
            'content': '',
          },
        ],
      );
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const ReviewScreen(),
          initialLocation: '/review',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('/etc/apt/sources.list'), findsOneWidget);
      expect(find.textContaining('Files to write'), findsOneWidget);
    });

    testWidgets(
      'apply_files section reflects user decisions, not profile defaults',
      (tester) async {
        final controller = await buildController(
          extraProfile: {
            'stock_os': {
              'files': [
                {
                  'id': 'keep_this',
                  'paths': ['/keep/me'],
                  'default_action': 'delete',
                },
                {
                  'id': 'delete_this',
                  'paths': ['/delete/me'],
                  'default_action': 'delete',
                },
              ],
            },
          },
          steps: [
            {'id': 'apply_files', 'kind': 'apply_files'},
          ],
          decisions: {
            // User reversed keep_this but left delete_this on default.
            'file.keep_this': 'keep',
            'file.delete_this': 'delete',
          },
        );
        await tester.pumpWidget(
          testHarness(
            controller: controller,
            child: const ReviewScreen(),
            initialLocation: '/review',
          ),
        );
        await tester.pumpAndSettle();
        // Preview should include `delete_this` but NOT `keep_this`.
        expect(find.textContaining('/delete/me'), findsOneWidget);
        expect(find.textContaining('/keep/me'), findsNothing);
      },
    );

    testWidgets('resolves firmware.install_path in template targets', (
      tester,
    ) async {
      final controller = await buildController(
        extraProfile: {
          'firmware': {
            'choices': [
              {
                'id': 'kalico',
                'display_name': 'Kalico',
                'repo': 'https://x',
                'ref': 'main',
                'install_path': '~/klipper',
              },
            ],
          },
        },
        steps: [
          {
            'id': 'write_cfg',
            'kind': 'write_file',
            'target': '{{firmware.install_path}}/klippy.cfg',
            'content': '',
          },
        ],
        decisions: {'firmware': 'kalico'},
      );
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const ReviewScreen(),
          initialLocation: '/review',
        ),
      );
      await tester.pumpAndSettle();
      // Template resolved at preview time, not rendered literally.
      expect(find.textContaining('~/klipper/klippy.cfg'), findsOneWidget);
      expect(find.textContaining('{{firmware.install_path}}'), findsNothing);
    });

    testWidgets('conditional-wrapped steps get a "(maybe)" tag', (
      tester,
    ) async {
      final controller = await buildController(
        steps: [
          {
            'id': 'gate',
            'kind': 'conditional',
            'when': 'os_codename_is("buster")',
            'then': [
              {
                'id': 'inner',
                'kind': 'write_file',
                'target': '/etc/apt/sources.list',
                'content': '',
              },
            ],
          },
        ],
      );
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const ReviewScreen(),
          initialLocation: '/review',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('(maybe, conditional)'), findsOneWidget);
      expect(find.textContaining('[gate: when os_codename_is'), findsOneWidget);
    });

    testWidgets('skips malformed nested step lists', (tester) async {
      final controller = await buildController(
        extraProfile: {
          'stock_os': {
            'paths': [
              {'id': 'config', 'path': '~/printer_data/config'},
            ],
          },
          'stack': {
            'moonraker': {
              'repo': 'https://example.com/moonraker.git',
              'install_path': '~/moonraker',
            },
          },
        },
        steps: [
          {
            'id': 'snapshot',
            'kind': 'snapshot_paths',
            'paths': ['config', 42],
          },
          {
            'id': 'stack',
            'kind': 'install_stack',
            'components': [42, 'moonraker'],
          },
          {
            'id': 'extras',
            'kind': 'link_extras',
            'sources': [42, '~/klippy/extras'],
          },
          {'id': 'gate', 'kind': 'conditional', 'then': 'not a list'},
          {
            'id': 'good_gate',
            'kind': 'conditional',
            'then': [
              'bad nested row',
              {'kind': 'script', 'path': '/tmp/deckhand.sh'},
            ],
          },
        ],
      );

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const ReviewScreen(),
          initialLocation: '/review',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('~/printer_data/config'), findsOneWidget);
      expect(
        find.textContaining('https://example.com/moonraker.git'),
        findsOneWidget,
      );
      expect(find.textContaining('~/klippy/extras'), findsOneWidget);
      await tester.ensureVisible(find.textContaining('Scripts to run'));
      await tester.tap(find.textContaining('Scripts to run'));
      await tester.pumpAndSettle();
      expect(find.textContaining('/tmp/deckhand.sh'), findsOneWidget);
      expect(find.textContaining('bad nested row'), findsNothing);
    });

    testWidgets('ignores malformed file decisions without crashing', (
      tester,
    ) async {
      final controller = await buildController(
        extraProfile: {
          'stock_os': {
            'files': [
              {
                'id': 'delete_this',
                'paths': ['/delete/me'],
                'default_action': 'delete',
              },
            ],
          },
        },
        steps: [
          {'id': 'apply_files', 'kind': 'apply_files'},
        ],
        decisions: {
          'file.delete_this': ['not', 'a', 'string'],
        },
      );

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const ReviewScreen(),
          initialLocation: '/review',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('/delete/me'), findsOneWidget);
    });

    testWidgets(
      'start install action is exposed as destructive after confirmation',
      (tester) async {
        final controller = await buildController(
          steps: [
            {
              'id': 'write_cfg',
              'kind': 'write_file',
              'target': '/etc/apt/sources.list',
              'content': '',
            },
          ],
        );
        final semantics = tester.ensureSemantics();

        await tester.pumpWidget(
          testHarness(
            controller: controller,
            child: const ReviewScreen(),
            initialLocation: '/review',
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('I understand and want to proceed.'));
        await tester.pumpAndSettle();

        expect(
          find.bySemanticsLabel('Start install, destructive'),
          findsOneWidget,
        );
        semantics.dispose();
      },
    );
  });
}
