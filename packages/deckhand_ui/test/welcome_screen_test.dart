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

      // The bottom-of-screen Start affordance still wires to the
      // same destination so keyboard/Enter advances the wizard.
      expect(find.text('Start'), findsOneWidget);

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
      expect(find.widgetWithText(TextButton, 'Discard'), findsOneWidget);
    });
  });
}
