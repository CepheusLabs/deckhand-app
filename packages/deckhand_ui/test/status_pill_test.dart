import 'package:deckhand_ui/deckhand_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// StatusPill reaches for [DeckhandTokens] via Theme.of(context). Tests
// must therefore wrap it in a MaterialApp configured with the Deckhand
// theme; a bare MaterialApp would assert at build time.
Widget wrap(Widget child) => MaterialApp(
      theme: DeckhandTheme.light(),
      home: Scaffold(body: child),
    );

void main() {
  group('StatusPill', () {
    testWidgets('plain constructor renders label with provided color',
        (tester) async {
      // The pill renders the label uppercased per the design spec
      // (text-transform: uppercase on `.pill`). Source label is
      // preserved for screen-reader consumers via [semanticsLabel].
      await tester.pumpWidget(
        wrap(const StatusPill(label: 'running', color: Colors.green)),
      );
      expect(find.text('RUNNING'), findsOneWidget);
    });

    testWidgets('bordered constructor adds a border',
        (tester) async {
      await tester.pumpWidget(
        wrap(const StatusPill.bordered(label: 'installed', color: Colors.blue)),
      );
      expect(find.text('INSTALLED'), findsOneWidget);
      // bordered variant renders a container with a non-null border.
      final container = tester.widget<Container>(
        find.ancestor(of: find.text('INSTALLED'), matching: find.byType(Container)),
      );
      final decoration = container.decoration as BoxDecoration;
      expect(decoration.border, isNotNull);
    });

    testWidgets(
        'fromKlippyState attaches a Semantics label for screen readers',
        (tester) async {
      await tester.pumpWidget(
        wrap(Builder(
          builder: (context) => StatusPill.fromKlippyState(context, 'ready'),
        )),
      );
      expect(find.text('READY'), findsOneWidget);
      // The Semantics node should carry a matching label.
      final semantics = tester.getSemantics(find.text('READY'));
      expect(semantics.label, contains('Klipper state ready'));
    });

    testWidgets('fromProfileStatus maps status string to label',
        (tester) async {
      await tester.pumpWidget(
        wrap(Builder(
          builder: (context) =>
              StatusPill.fromProfileStatus(context, 'alpha'),
        )),
      );
      expect(find.text('ALPHA'), findsOneWidget);
    });
  });
}
