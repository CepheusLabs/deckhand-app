import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/screens/manage_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  testWidgets('status tab copies profile web ui port and session ssh user', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = stubWizardController(
      profileJson: testProfileJson(
        stack: const {
          'webui': {'port': 8808},
        },
      ),
    );
    await controller.loadProfile('test-printer');
    controller.setSession(
      const SshSession(id: 's', host: '192.168.1.50', port: 22, user: 'mks'),
    );
    final clipboardWrites = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          final data = (call.arguments as Map?)?['text'] as String?;
          if (data != null) clipboardWrites.add(data);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      testHarness(
        controller: controller,
        child: const ManageScreen(),
        initialLocation: '/manage',
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Copy Web UI URL'));
    await tester.pump();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Copy SSH command'));
    await tester.pump();

    expect(clipboardWrites, contains('http://192.168.1.50:8808'));
    expect(clipboardWrites, contains('ssh mks@192.168.1.50'));
  });
}
