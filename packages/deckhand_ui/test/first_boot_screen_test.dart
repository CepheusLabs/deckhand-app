import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/providers.dart';
import 'package:deckhand_ui/src/screens/first_boot_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('FirstBootScreen', () {
    testWidgets('timeout explains what to do next and keeps retry available', (
      tester,
    ) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      controller.setSession(
        const SshSession(
          id: 'stub',
          host: '192.168.1.50',
          port: 22,
          user: 'root',
        ),
      );

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const FirstBootScreen(),
          initialLocation: '/first-boot',
          extraOverrides: [
            discoveryServiceProvider.overrideWithValue(
              const _TimeoutDiscovery(),
            ),
          ],
        ),
      );
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, 'Start polling'));
      await tester.pump();
      await tester.pump();

      expect(find.text('No SSH response yet.'), findsOneWidget);
      expect(
        find.textContaining('Check that the eMMC is installed'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(FilledButton, 'Retry polling'),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextButton, 'Choose printer'), findsOneWidget);
    });

    testWidgets('poll errors do not leave the screen stuck waiting', (
      tester,
    ) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      controller.setSession(
        const SshSession(
          id: 'stub',
          host: '192.168.1.50',
          port: 22,
          user: 'root',
        ),
      );

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const FirstBootScreen(),
          initialLocation: '/first-boot',
          extraOverrides: [
            discoveryServiceProvider.overrideWithValue(
              const _ThrowingDiscovery(),
            ),
          ],
        ),
      );
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, 'Start polling'));
      await tester.pump();
      await tester.pump();

      expect(find.text('No SSH response yet.'), findsOneWidget);
      expect(find.textContaining('Deckhand could not check SSH'), findsOne);
      expect(
        find.widgetWithText(FilledButton, 'Retry polling'),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Waiting…'), findsNothing);
    });
  });
}

class _TimeoutDiscovery implements DiscoveryService {
  const _TimeoutDiscovery();

  @override
  Future<List<DiscoveredPrinter>> scanCidr({
    required String cidr,
    int port = 7125,
    Duration timeout = const Duration(seconds: 5),
  }) async => const [];

  @override
  Future<List<DiscoveredPrinter>> scanMdns({
    Duration timeout = const Duration(seconds: 5),
  }) async => const [];

  @override
  Future<bool> waitForSsh({
    required String host,
    int port = 22,
    Duration timeout = const Duration(minutes: 10),
  }) async => false;
}

class _ThrowingDiscovery implements DiscoveryService {
  const _ThrowingDiscovery();

  @override
  Future<List<DiscoveredPrinter>> scanCidr({
    required String cidr,
    int port = 7125,
    Duration timeout = const Duration(seconds: 5),
  }) async => const [];

  @override
  Future<List<DiscoveredPrinter>> scanMdns({
    Duration timeout = const Duration(seconds: 5),
  }) async => const [];

  @override
  Future<bool> waitForSsh({
    required String host,
    int port = 22,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    throw StateError('socket connect failed');
  }
}
