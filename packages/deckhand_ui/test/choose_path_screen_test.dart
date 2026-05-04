import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/screens/choose_path_screen.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('ChoosePathScreen', () {
    testWidgets('renders both path cards and defaults to stockKeep',
        (tester) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const ChoosePathScreen(),
          initialLocation: '/choose-path',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Keep my current OS'), findsOneWidget);
      // Copy was tightened in the design pass — "Flash a fresh OS"
      // matches the design language reference.
      expect(find.textContaining('Flash a fresh OS'), findsOneWidget);
      expect(find.text('Continue'), findsOneWidget);
      expect(find.text('Back'), findsOneWidget);
    });

    testWidgets('Continue writes the default stockKeep flow',
        (tester) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const ChoosePathScreen(),
          initialLocation: '/choose-path',
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      // Screen defaults to stockKeep on first render; Continue
      // records that default on the controller.
      expect(controller.state.flow, WizardFlow.stockKeep);
    });
  });
}
