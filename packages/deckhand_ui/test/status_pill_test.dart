import 'package:deckhand_ui/src/widgets/status_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StatusPill', () {
    testWidgets('plain constructor renders label with provided color',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: StatusPill(label: 'running', color: Colors.green),
          ),
        ),
      );
      expect(find.text('running'), findsOneWidget);
    });

    testWidgets('bordered constructor adds a border',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: StatusPill.bordered(label: 'installed', color: Colors.blue),
          ),
        ),
      );
      expect(find.text('installed'), findsOneWidget);
      // bordered variant renders a container with a non-null border.
      final container = tester.widget<Container>(
        find.ancestor(of: find.text('installed'), matching: find.byType(Container)),
      );
      final decoration = container.decoration as BoxDecoration;
      expect(decoration.border, isNotNull);
    });

    testWidgets(
        'fromKlippyState attaches a Semantics label for screen readers',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => StatusPill.fromKlippyState(context, 'ready'),
            ),
          ),
        ),
      );
      expect(find.text('ready'), findsOneWidget);
      // The Semantics node should carry a matching label.
      final semantics = tester.getSemantics(find.text('ready'));
      expect(semantics.label, contains('Klipper state ready'));
    });

    testWidgets('fromProfileStatus maps status string to label',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) =>
                  StatusPill.fromProfileStatus(context, 'alpha'),
            ),
          ),
        ),
      );
      expect(find.text('alpha'), findsOneWidget);
    });
  });
}
