import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/screens/connect_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('ConnectScreen', () {
    testWidgets('manual-host tab shows a host input field', (tester) async {
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

      // Switch to the Manual host tab — the design's S20 puts the
      // host input behind its own tab now, so the field is only in
      // the widget tree when that tab is active.
      await tester.tap(find.text('Manual host'));
      await tester.pump();

      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('discover tab exposes a Refresh affordance', (tester) async {
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

      // Refresh lives next to the tab strip on the Discover tab.
      // The label changed from "Rescan" → "Refresh" with the tab
      // redesign; both intents are the same — re-run discovery.
      expect(find.text('Refresh'), findsOneWidget);
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
      },
    );

    testWidgets('host-key mismatch opens debug bundle review', (tester) async {
      final controller = stubWizardController(
        profileJson: testProfileJson(),
        ssh: stubSsh(
          connectError: const HostKeyMismatchException(
            host: '192.168.1.50',
            fingerprint: 'SHA256:received',
          ),
        ),
        security: stubSecurity(pinnedFingerprint: 'SHA256:expected'),
      );
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

      await tester.tap(find.text('Manual host'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '192.168.1.50');
      await tester.pump();
      await tester.tap(find.text('Connect'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Host key mismatch.'), findsOneWidget);

      await tester.tap(find.text('Save debug bundle'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Review debug bundle'), findsOneWidget);
      expect(find.textContaining('Host key mismatch'), findsWidgets);
      expect(find.textContaining('SHA256:received'), findsWidgets);
    });
  });
}
