import 'package:deckhand_ui/src/theming/deckhand_theme.dart';
import 'package:deckhand_ui/src/widgets/wizard_progress_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('progress bar ticks include the 100 percent endpoint', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: DeckhandTheme.light(),
        home: const Scaffold(
          body: SizedBox(
            width: 500,
            child: WizardProgressBar(fraction: 0.5),
          ),
        ),
      ),
    );

    expect(find.text('0%'), findsOneWidget);
    expect(find.text('25%'), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);
    expect(find.text('75%'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
  });
}
