import 'package:deckhand_ui/src/screens/connect_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('ConnectScreen', () {
    testWidgets('renders the manual-host section when discovery is empty',
        (tester) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const ConnectScreen(),
          initialLocation: '/connect',
        ),
      );
      // Let the async mDNS + CIDR sweeps resolve (stubbed to return
      // empty). pumpAndSettle would block on the scan's own delays,
      // so we just pump a few frames.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Manual host field and Rescan button are present.
      expect(find.byType(TextField), findsOneWidget);
      expect(find.textContaining('Rescan'), findsOneWidget);
    });

    testWidgets(
        'discovered card detail uses "Printer found" (not "Moonraker")',
        (tester) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const ConnectScreen(),
          initialLocation: '/connect',
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Developer-jargon check: "Moonraker" label must NOT be
      // surfaced as a card detail.
      expect(find.text('Moonraker'), findsNothing);
    });
  });
}
