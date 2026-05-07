import 'package:deckhand_ui/src/screens/firmware_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('FirmwareScreen', () {
    testWidgets('renders every firmware choice with its display_name', (
      tester,
    ) async {
      final controller = stubWizardController(
        profileJson: {
          ...testProfileJson(),
          'firmware': {
            'choices': [
              {
                'id': 'kalico',
                'display_name': 'Kalico',
                'description': 'Community Klipper fork',
                'repo': 'https://github.com/KalicoCrew/kalico',
                'ref': 'main',
                'recommended': true,
              },
              {
                'id': 'klipper',
                'display_name': 'Klipper',
                'description': 'Upstream Klipper',
                'repo': 'https://github.com/Klipper3d/klipper',
                'ref': 'master',
              },
            ],
          },
        },
      );
      await controller.loadProfile('test-printer');
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const FirmwareScreen(),
          initialLocation: '/firmware',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Kalico'), findsOneWidget);
      expect(find.text('Klipper'), findsOneWidget);
      expect(find.text('Recommended'), findsOneWidget);
    });

    testWidgets('git repo + ref are NOT rendered in the card subtitle', (
      tester,
    ) async {
      final controller = stubWizardController(
        profileJson: {
          ...testProfileJson(),
          'firmware': {
            'choices': [
              {
                'id': 'kalico',
                'display_name': 'Kalico',
                'description': 'Kalico is great',
                'repo': 'https://github.com/KalicoCrew/kalico',
                'ref': 'main',
              },
            ],
          },
        },
      );
      await controller.loadProfile('test-printer');
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const FirmwareScreen(),
          initialLocation: '/firmware',
        ),
      );
      await tester.pumpAndSettle();

      // Description lands in the card body.
      expect(find.textContaining('Kalico is great'), findsOneWidget);
      // Repo URL + ref should NOT be user-visible (they live in the
      // info-icon tooltip instead).
      expect(find.textContaining('github.com/KalicoCrew/kalico'), findsNothing);
      expect(find.textContaining(' @ main'), findsNothing);
    });

    testWidgets('Continue advances to /webui after recording firmware choice', (
      tester,
    ) async {
      final controller = stubWizardController(
        profileJson: {
          ...testProfileJson(),
          'firmware': {
            'choices': [
              {
                'id': 'kalico',
                'display_name': 'Kalico',
                'repo': 'https://github.com/KalicoCrew/kalico',
                'ref': 'main',
                'recommended': true,
              },
            ],
            'default_choice': 'kalico',
          },
        },
      );
      await controller.loadProfile('test-printer');
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const FirmwareScreen(),
          initialLocation: '/firmware',
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
      await tester.pumpAndSettle();
      expect(controller.decision<String>('firmware'), 'kalico');
    });

    testWidgets('seeds from existing firmware decision before default', (
      tester,
    ) async {
      final controller = stubWizardController(
        profileJson: {
          ...testProfileJson(),
          'firmware': {
            'choices': [
              {
                'id': 'kalico',
                'display_name': 'Kalico',
                'repo': 'https://github.com/KalicoCrew/kalico',
                'ref': 'main',
                'recommended': true,
              },
              {
                'id': 'klipper',
                'display_name': 'Klipper',
                'repo': 'https://github.com/Klipper3d/klipper',
                'ref': 'master',
              },
            ],
            'default_choice': 'kalico',
          },
        },
      );
      await controller.loadProfile('test-printer');
      await controller.setDecision('firmware', 'klipper');
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const FirmwareScreen(),
          initialLocation: '/firmware',
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
      await tester.pumpAndSettle();
      expect(controller.decision<String>('firmware'), 'klipper');
    });
  });
}
