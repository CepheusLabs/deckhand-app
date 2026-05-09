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

    testWidgets('uses a friendly fallback when the disk model is raw', (
      tester,
    ) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      final flash = _MutableFlashService([
        const DiskInfo(
          id: 'PhysicalDrive3',
          path: r'\\.\PhysicalDrive3',
          sizeBytes: 32 * 1024 * 1024 * 1024,
          bus: 'USB',
          model: '',
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

      expect(find.text('Generic STORAGE DEVICE'), findsOneWidget);
      expect(find.text('PhysicalDrive3'), findsNothing);
    });

    testWidgets('sanitizes disk enumeration errors', (tester) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const FlashTargetScreen(),
          initialLocation: '/flash-target',
          extraOverrides: [
            flashServiceProvider.overrideWithValue(
              const _FailingFlashService(),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Error listing disks'), findsOneWidget);
      expect(find.textContaining('Windows disk 3'), findsOneWidget);
      expect(find.textContaining('PHYSICALDRIVE3'), findsNothing);
      expect(find.textContaining('StateError'), findsNothing);
    });
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

class _FailingFlashService implements FlashService {
  const _FailingFlashService();

  @override
  Future<List<DiskInfo>> listDisks() async =>
      throw StateError(r'Get-Disk failed for \\.\PHYSICALDRIVE3');

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
