import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/deckhand_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpScaffold(
    WidgetTester tester, {
    required VoidCallback? onPrimary,
    VoidCallback? onBack,
    bool destructive = false,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deckhandSettingsProvider.overrideWithValue(
            DeckhandSettings(path: '<memory>'),
          ),
        ],
        child: MaterialApp(
          theme: DeckhandTheme.light(),
          home: WizardScaffold(
            title: 'Test',
            body: const SizedBox.shrink(),
            primaryAction: WizardAction(
              label: 'Continue',
              onPressed: onPrimary,
              destructive: destructive,
            ),
            secondaryActions: [
              if (onBack != null)
                WizardAction(label: 'Back', onPressed: onBack, isBack: true),
            ],
          ),
        ),
      ),
    );
    // First frame sets up the Focus; give it a chance to grab focus.
    await tester.pump();
  }

  testWidgets('Enter fires the primary action', (tester) async {
    var clicked = 0;
    await pumpScaffold(tester, onPrimary: () => clicked++);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(clicked, 1);
  });

  testWidgets('Numpad Enter also fires the primary action', (tester) async {
    var clicked = 0;
    await pumpScaffold(tester, onPrimary: () => clicked++);
    await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
    await tester.pump();
    expect(clicked, 1);
  });

  testWidgets('Escape fires the Back action when present', (tester) async {
    var back = 0;
    await pumpScaffold(tester, onPrimary: () {}, onBack: () => back++);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(back, 1);
  });

  testWidgets('Enter does NOT fire a destructive action', (tester) async {
    var clicked = 0;
    await pumpScaffold(tester, onPrimary: () => clicked++, destructive: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    // Destructive actions must require a real click — never a
    // press-and-hold / stray-Enter accident during a flash-confirm.
    expect(clicked, 0);
  });

  testWidgets('Enter on a disabled primary action is a no-op', (tester) async {
    await pumpScaffold(tester, onPrimary: null);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    // No assertion needed — the test passes if no exception is
    // thrown when the CallbackAction's null onPressed fires.
  });

  testWidgets('Escape with no Back action is a no-op', (tester) async {
    await pumpScaffold(tester, onPrimary: () {});
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
  });

  testWidgets('primary Back action renders on the left and receives Esc', (
    tester,
  ) async {
    var back = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deckhandSettingsProvider.overrideWithValue(
            DeckhandSettings(path: '<memory>'),
          ),
        ],
        child: MaterialApp(
          theme: DeckhandTheme.light(),
          home: WizardScaffold(
            title: 'Test',
            body: const SizedBox.shrink(),
            primaryAction: WizardAction(
              label: 'Back',
              onPressed: () => back++,
              isBack: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.widgetWithText(OutlinedButton, 'Back'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Back'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(back, 1);
  });

  testWidgets('English label without isBack does NOT receive Esc', (
    tester,
  ) async {
    // After removing the legacy English-label heuristic, a back-action
    // that forgot `isBack: true` is correctly not bound to Esc. This
    // test pins the contract so a future revert can't quietly bring
    // the locale-dependent fallback back.
    var cancel = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deckhandSettingsProvider.overrideWithValue(
            DeckhandSettings(path: '<memory>'),
          ),
        ],
        child: MaterialApp(
          theme: DeckhandTheme.light(),
          home: WizardScaffold(
            title: 'Test',
            body: const SizedBox.shrink(),
            primaryAction: WizardAction(label: 'Continue', onPressed: () {}),
            secondaryActions: [
              WizardAction(label: 'Cancel', onPressed: () => cancel++),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(cancel, 0, reason: 'no isBack flag means no Esc binding');
  });

  testWidgets('footer actions do not overflow in a narrow window', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deckhandSettingsProvider.overrideWithValue(
            DeckhandSettings(path: '<memory>'),
          ),
        ],
        child: MaterialApp(
          theme: DeckhandTheme.light(),
          home: WizardScaffold(
            title: 'Test',
            body: const SizedBox.shrink(),
            primaryAction: WizardAction(
              label: 'Continue to selected restore target',
              onPressed: () {},
            ),
            secondaryActions: [
              WizardAction(
                label: 'Back to backup selection',
                onPressed: () {},
                isBack: true,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Back to backup selection'), findsOneWidget);
    expect(find.text('Continue to selected restore target'), findsOneWidget);
  });
}
