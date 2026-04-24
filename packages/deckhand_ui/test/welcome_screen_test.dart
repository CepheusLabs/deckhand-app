import 'package:deckhand_ui/src/screens/welcome_screen.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('WelcomeScreen', () {
    testWidgets('renders welcome copy, Start action, and Settings secondary',
        (tester) async {
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

      // Welcome headline. Present at least once; the scaffold may
      // render it in a header AND a semantics label so don't pin to
      // findsOneWidget.
      expect(find.textContaining('Welcome'), findsWidgets);
      expect(find.text('Start'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
      // Both help cards render.
      expect(find.textContaining('First time here'), findsWidgets);
      expect(find.text('Safety'), findsOneWidget);
    });
  });
}
