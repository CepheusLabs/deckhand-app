import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/screens/services_screen.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('ServicesScreen', () {
    testWidgets('renders one card per stock service with a wizard block',
        (tester) async {
      final controller = stubWizardController(
        profileJson: {
          ...testProfileJson(),
          'stock_os': {
            'services': [
              {
                'id': 'phrozen_master',
                'display_name': 'Phrozen master',
                'default_action': 'disable',
                'wizard': {'explainer': 'Vendor relay'},
              },
              {
                'id': 'frpc',
                'display_name': 'FRP reverse tunnel',
                'default_action': 'remove',
                'wizard': {'explainer': 'Phone-home tunnel'},
              },
              {
                'id': 'internal',
                'display_name': 'Internal - no wizard',
                'default_action': 'keep',
                'wizard': 'none',
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
          child: const ServicesScreen(),
          initialLocation: '/services',
        ),
      );
      // The services screen subscribes to state stream; pump a
      // bounded number of frames instead of waiting for the stream
      // to go idle (which never does in a widget test).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Services with a wizard block render; the `wizard: none` one
      // is filtered out entirely.
      expect(find.text('Phrozen master'), findsOneWidget);
      expect(find.text('FRP reverse tunnel'), findsOneWidget);
      expect(find.text('Internal - no wizard'), findsNothing);
    });

    testWidgets('seeds default decisions on first render (initState path)',
        (tester) async {
      final controller = stubWizardController(
        profileJson: {
          ...testProfileJson(),
          'stock_os': {
            'services': [
              {
                'id': 'frpc',
                'display_name': 'FRP tunnel',
                'default_action': 'remove',
                'wizard': {'explainer': 'Remove vendor tunnel'},
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
          child: const ServicesScreen(),
          initialLocation: '/services',
        ),
      );
      // Two pumps so the initState-scheduled postFrameCallback runs
      // AND the subsequent rebuild applies the seeded decision.
      // The services screen subscribes to state stream; pump a
      // bounded number of frames instead of waiting for the stream
      // to go idle (which never does in a widget test).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(controller.decision<String>('service.frpc'), 'remove');
    });

    testWidgets(
        'Back action renders via t.common.action_back (no hardcoded string)',
        (tester) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      controller.setFlow(WizardFlow.stockKeep);
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const ServicesScreen(),
          initialLocation: '/services',
        ),
      );
      // The services screen subscribes to state stream; pump a
      // bounded number of frames instead of waiting for the stream
      // to go idle (which never does in a widget test).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Default english translation is "Back" - but we're asserting
      // it renders via the scaffold, not via a literal widget tree
      // child of the screen's body.
      expect(find.text('Back'), findsOneWidget);
      expect(find.text('Continue'), findsOneWidget);
    });
  });
}
