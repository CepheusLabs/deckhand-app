import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/providers.dart';
import 'package:deckhand_ui/src/screens/flash_target_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('FlashTargetScreen', () {
    testWidgets(
      'disables continue when the selected disk disappears after refresh',
      (tester) async {
        final controller = stubWizardController(profileJson: testProfileJson());
        await controller.loadProfile('test-printer');
        final flash = _MutableFlashService([
          const DiskInfo(
            id: 'disk-1',
            path: r'\\.\PhysicalDrive3',
            sizeBytes: 4096,
            bus: 'USB',
            model: 'Test eMMC',
            removable: true,
            partitions: [],
          ),
        ]);

        await tester.pumpWidget(
          testHarness(
            controller: controller,
            child: const FlashTargetScreen(),
            initialLocation: '/flash-target',
            extraOverrides: [flashServiceProvider.overrideWithValue(flash)],
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Test eMMC'));
        await tester.pumpAndSettle();
        expect(_primaryButton(tester).onPressed, isNotNull);

        flash.disks = const [];
        await tester.tap(find.text('Refresh'));
        await tester.pumpAndSettle();

        expect(_primaryButton(tester).onPressed, isNull);
        expect(
          controller.decision<String>('flash.disk'),
          isNull,
          reason: 'A stale disk selection must not be committed.',
        );
      },
    );
  });
}

FilledButton _primaryButton(WidgetTester tester) {
  final finder = find.widgetWithText(FilledButton, 'Use this disk');
  expect(finder, findsOneWidget);
  return tester.widget<FilledButton>(finder);
}

class _MutableFlashService implements FlashService {
  _MutableFlashService(this.disks);

  List<DiskInfo> disks;

  @override
  Future<List<DiskInfo>> listDisks() async => disks;

  @override
  Future<FlashSafetyVerdict> safetyCheck({required String diskId}) async =>
      FlashSafetyVerdict(diskId: diskId, allowed: true);

  @override
  Stream<FlashProgress> readImage({
    required String diskId,
    required String outputPath,
  }) => const Stream.empty();

  @override
  Future<String> sha256(String path) async => '';

  @override
  Stream<FlashProgress> writeImage({
    required String imagePath,
    required String diskId,
    required String confirmationToken,
    bool verifyAfterWrite = true,
  }) => const Stream.empty();
}
