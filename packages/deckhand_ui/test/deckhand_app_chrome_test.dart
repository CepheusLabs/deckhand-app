import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/providers.dart';
import 'package:deckhand_ui/src/theming/deckhand_theme.dart';
import 'package:deckhand_ui/src/widgets/deckhand_app_chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  testWidgets('top bar exposes the printer registry', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const DeckhandAppChrome(child: SizedBox.expand()),
        ),
        GoRoute(
          path: '/printers',
          builder: (_, _) => const DeckhandAppChrome(
            child: Center(child: Text('Printers route')),
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deckhandSettingsProvider.overrideWithValue(
            DeckhandSettings(path: '<memory>'),
          ),
          wizardStateProvider.overrideWith(
            (_) => Stream.value(WizardState.initial()),
          ),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          theme: DeckhandTheme.light(),
          darkTheme: DeckhandTheme.dark(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextButton, 'Printers'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Printers'));
    await tester.pumpAndSettle();

    expect(find.text('Printers route'), findsOneWidget);
  });
}
