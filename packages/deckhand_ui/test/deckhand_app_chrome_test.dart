import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/providers.dart';
import 'package:deckhand_ui/src/widgets/deckhand_app_chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/forge.dart';
import 'package:go_router/go_router.dart';
import 'package:printdeck_product_platform/printdeck_product_platform.dart';

void main() {
  testWidgets('command bar renders brand, footbar, and global affordances', (
    tester,
  ) async {
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
          theme: buildClTheme(
            brightness: Brightness.light,
            density: ClDensity.compact,
            accentPalette: ClAccentPalette.violet,
          ),
          darkTheme: buildClTheme(
            brightness: Brightness.dark,
            density: ClDensity.compact,
            accentPalette: ClAccentPalette.violet,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ProductShellFrame), findsOneWidget);
    expect(find.byType(ClCommandBar), findsOneWidget);
    expect(find.text('Deckhand'), findsOneWidget);
    // Footbar still renders the sidecar version cell (label uppercased).
    expect(find.text('SIDECAR'), findsOneWidget);
    // Global affordances: settings button + the 3-way theme toggle.
    expect(find.byTooltip('Settings'), findsOneWidget);
    expect(find.byType(ClThemeToggle), findsOneWidget);
    // Cross-cutting nav pill.
    expect(find.widgetWithText(ClNavPill, 'Printers'), findsOneWidget);

    await tester.tap(find.widgetWithText(ClNavPill, 'Printers'));
    await tester.pumpAndSettle();

    expect(find.text('Printers route'), findsOneWidget);
  });
}
