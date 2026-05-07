import 'dart:async';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/providers.dart';
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

  testWidgets('restore tab surfaces indexed backups and arms restore action', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final disk = const DiskInfo(
      id: 'PhysicalDrive3',
      path: r'\\.\PHYSICALDRIVE3',
      sizeBytes: 8 * 1024 * 1024,
      bus: 'USB',
      model: 'Generic STORAGE DEVICE',
      removable: true,
      partitions: [
        PartitionInfo(index: 1, filesystem: 'FAT32', sizeBytes: 1024 * 1024),
      ],
    );
    const sha =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final manifest = EmmcBackupManifest.create(
      profileId: 'test-printer',
      imagePath: r'C:\Deckhand\emmc-backups\test-printer-emmc.img',
      imageBytes: disk.sizeBytes,
      imageSha256: sha,
      disk: disk,
      deckhandVersion: 'test',
    );

    final controller = stubWizardController(profileJson: testProfileJson());
    await controller.loadProfile('test-printer');

    await tester.pumpWidget(
      testHarness(
        controller: controller,
        child: const ManageScreen(),
        initialLocation: '/manage',
        extraOverrides: [
          emmcBackupManifestsProvider.overrideWith((ref) async => [manifest]),
          flashServiceProvider.overrideWithValue(
            _RestoreFlash(disks: [disk], sha256Value: sha),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.text('Restore').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('RESTORE EMMC IMAGE'), findsOneWidget);
    expect(find.textContaining('Generic STORAGE DEVICE'), findsWidgets);

    await tester.enterText(
      find.byType(TextField).last,
      'Generic STORAGE DEVICE',
    );
    await tester.pump();
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Restore backup'),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('direct eMMC restore screen reuses restore flow', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final disk = const DiskInfo(
      id: 'PhysicalDrive3',
      path: r'\\.\PHYSICALDRIVE3',
      sizeBytes: 8 * 1024 * 1024,
      bus: 'USB',
      model: 'Generic STORAGE DEVICE',
      removable: true,
      partitions: [],
    );
    const sha =
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    final manifest = EmmcBackupManifest.create(
      profileId: 'test-printer',
      imagePath: r'C:\Deckhand\emmc-backups\rollback.img',
      imageBytes: disk.sizeBytes,
      imageSha256: sha,
      disk: disk,
      deckhandVersion: 'test',
    );

    final controller = stubWizardController(profileJson: testProfileJson());
    await controller.loadProfile('test-printer');

    await tester.pumpWidget(
      testHarness(
        controller: controller,
        child: const EmmcRestoreScreen(),
        initialLocation: '/emmc-restore',
        extraOverrides: [
          emmcBackupManifestsProvider.overrideWith((ref) async => [manifest]),
          flashServiceProvider.overrideWithValue(
            _RestoreFlash(disks: [disk], sha256Value: sha),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Restore an eMMC backup.'), findsOneWidget);
    expect(find.text('RESTORE EMMC IMAGE'), findsOneWidget);
    expect(find.textContaining('Generic STORAGE DEVICE'), findsWidgets);
  });

  testWidgets('direct eMMC restore empty state stays in recovery flow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = stubWizardController(profileJson: testProfileJson());
    await controller.loadProfile('test-printer');

    await tester.pumpWidget(
      testHarness(
        controller: controller,
        child: const EmmcRestoreScreen(),
        initialLocation: '/emmc-restore',
        extraOverrides: [
          emmcBackupManifestsProvider.overrideWith((ref) async => const []),
          emmcBackupImageCandidatesProvider.overrideWith(
            (ref) async => const [],
          ),
          emmcBackupsDirProvider.overrideWithValue(r'C:\Deckhand\emmc-backups'),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.textContaining('No eMMC backup images were found'), findsOne);
    expect(find.text('Open backup flow'), findsNothing);
    expect(find.textContaining(r'C:\Deckhand\emmc-backups'), findsOneWidget);
  });

  testWidgets('direct eMMC restore can use unindexed image candidates', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final disk = const DiskInfo(
      id: 'PhysicalDrive3',
      path: r'\\.\PHYSICALDRIVE3',
      sizeBytes: 8 * 1024 * 1024,
      bus: 'USB',
      model: 'Generic STORAGE DEVICE',
      removable: true,
      partitions: [],
    );
    final candidate = EmmcBackupImageCandidate(
      imagePath: r'C:\Deckhand\emmc-backups\deckhand-cli-backup.img',
      imageBytes: disk.sizeBytes,
      modifiedAt: DateTime.utc(2026, 5, 4, 12),
      inferredProfileId: null,
    );

    final controller = stubWizardController(profileJson: testProfileJson());
    await controller.loadProfile('test-printer');

    await tester.pumpWidget(
      testHarness(
        controller: controller,
        child: const EmmcRestoreScreen(),
        initialLocation: '/emmc-restore',
        extraOverrides: [
          emmcBackupManifestsProvider.overrideWith((ref) async => const []),
          emmcBackupImageCandidatesProvider.overrideWith(
            (ref) async => [candidate],
          ),
          flashServiceProvider.overrideWithValue(
            _RestoreFlash(
              disks: [disk],
              sha256Value:
                  'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
            ),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.textContaining('deckhand-cli-backup.img'), findsOneWidget);
    expect(find.textContaining('unindexed image'), findsWidgets);
    expect(find.textContaining('Generic STORAGE DEVICE'), findsWidgets);

    await tester.enterText(
      find.byType(TextField).last,
      'Generic STORAGE DEVICE',
    );
    await tester.pump();
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Restore backup'),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('direct eMMC restore can use smaller images for drive upgrades', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final disk = const DiskInfo(
      id: 'PhysicalDrive3',
      path: r'\\.\PHYSICALDRIVE3',
      sizeBytes: 16 * 1024 * 1024,
      bus: 'USB',
      model: 'Generic STORAGE DEVICE',
      removable: true,
      partitions: [],
    );
    final smallerCandidate = EmmcBackupImageCandidate(
      imagePath: r'C:\Deckhand\emmc-backups\restore-smaller.img',
      imageBytes: 8 * 1024 * 1024,
      modifiedAt: DateTime.utc(2026, 5, 4, 12),
      inferredProfileId: 'phrozen-arco',
    );

    final controller = stubWizardController(profileJson: testProfileJson());
    await controller.loadProfile('test-printer');

    await tester.pumpWidget(
      testHarness(
        controller: controller,
        child: const EmmcRestoreScreen(),
        initialLocation: '/emmc-restore',
        extraOverrides: [
          emmcBackupManifestsProvider.overrideWith((ref) async => const []),
          emmcBackupImageCandidatesProvider.overrideWith(
            (ref) async => [smallerCandidate],
          ),
          flashServiceProvider.overrideWithValue(
            _RestoreFlash(
              disks: [disk],
              sha256Value:
                  'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
            ),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.textContaining('restore-smaller.img'), findsOneWidget);
    expect(find.textContaining('Generic STORAGE DEVICE'), findsWidgets);

    await tester.enterText(
      find.byType(TextField).last,
      'Generic STORAGE DEVICE',
    );
    await tester.pump();
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Restore backup'),
    );
    expect(button.onPressed, isNotNull);
  });
}

class _RestoreFlash implements FlashService {
  _RestoreFlash({required this.disks, required this.sha256Value});

  final List<DiskInfo> disks;
  final String sha256Value;

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
  Future<String> sha256(String path) async => sha256Value;

  @override
  Stream<FlashProgress> writeImage({
    required String imagePath,
    required String diskId,
    required String confirmationToken,
    bool verifyAfterWrite = true,
  }) => const Stream.empty();
}
