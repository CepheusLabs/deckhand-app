import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/providers.dart';
import 'package:deckhand_ui/src/screens/flash_target_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  testWidgets('surfaces interrupted flash state on matching disk', (
    tester,
  ) async {
    final controller = stubWizardController(profileJson: testProfileJson());
    await controller.loadProfile('test-printer');
    final flash = _FlashServiceWithDisks([
      DiskInfo(
        id: 'PhysicalDrive3',
        path: r'\\.\PhysicalDrive3',
        sizeBytes: 7818182656,
        bus: 'USB',
        model: 'Generic STORAGE DEVICE',
        removable: true,
        partitions: const [],
        interruptedFlash: InterruptedFlashInfo(
          startedAt: DateTime.utc(2026, 5, 4, 14, 30),
          imagePath: r'C:\Deckhand\images\arco.img',
          imageSha256: 'a' * 64,
        ),
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

    expect(find.text('INTERRUPTED'), findsOneWidget);
    expect(
      find.textContaining('Previous Deckhand flash did not finish'),
      findsOneWidget,
    );

    await tester.tap(find.text('Generic STORAGE DEVICE'));
    await tester.pumpAndSettle();
    final primary = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Use this disk'),
    );
    expect(primary.onPressed, isNotNull);
  });
}

class _FlashServiceWithDisks implements FlashService {
  const _FlashServiceWithDisks(this.disks);

  final List<DiskInfo> disks;

  @override
  Future<List<DiskInfo>> listDisks() async => disks;

  @override
  Stream<FlashProgress> readImage({
    required String diskId,
    required String outputPath,
  }) => const Stream.empty();

  @override
  Future<FlashSafetyVerdict> safetyCheck({required String diskId}) async =>
      FlashSafetyVerdict(diskId: diskId, allowed: true);

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
