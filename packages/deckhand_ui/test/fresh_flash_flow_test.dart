import 'dart:async';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/providers.dart';
import 'package:deckhand_ui/src/screens/choose_os_screen.dart';
import 'package:deckhand_ui/src/screens/flash_confirm_screen.dart';
import 'package:deckhand_ui/src/screens/flash_target_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('fresh flash wizard flow', () {
    testWidgets('FlashTargetScreen only records a removable disk selection', (
      tester,
    ) async {
      final controller = stubWizardController(profileJson: _profileJson());
      await controller.loadProfile('test-printer');

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const FlashTargetScreen(),
          initialLocation: '/flash-target',
          extraOverrides: [
            flashServiceProvider.overrideWithValue(_FlashDisks()),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Host NVMe'), findsOneWidget);
      expect(find.text('Printer eMMC'), findsOneWidget);

      await tester.tap(find.text('Host NVMe'));
      await tester.pump();
      var useDisk = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Use this disk'),
      );
      expect(useDisk.onPressed, isNull);

      await tester.tap(find.text('Printer eMMC'));
      await tester.pump();
      useDisk = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Use this disk'),
      );
      expect(useDisk.onPressed, isNotNull);

      await tester.tap(find.text('Use this disk'));
      await tester.pump();

      expect(controller.decision<String>('flash.disk'), 'disk-emmc');
    });

    testWidgets('ChooseOsScreen defaults to the recommended image', (
      tester,
    ) async {
      final controller = stubWizardController(profileJson: _profileJson());
      await controller.loadProfile('test-printer');
      await controller.setDecision('flash.disk', 'disk-emmc');

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const ChooseOsScreen(),
          initialLocation: '/choose-os',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Debian 12 stable'), findsOneWidget);
      expect(find.text('Debian 13 preview'), findsOneWidget);

      await tester.tap(find.text('Continue'));
      await tester.pump();

      expect(controller.decision<String>('flash.os'), 'debian-bookworm');
    });

    testWidgets('FlashConfirmScreen reflects an existing full-size backup', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = stubWizardController(profileJson: _profileJson());
      await controller.loadProfile('test-printer');
      await controller.setDecision('flash.disk', 'disk-emmc');
      await controller.setDecision('flash.os', 'debian-bookworm');

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const FlashConfirmScreen(),
          initialLocation: '/flash-confirm',
          extraOverrides: [
            flashServiceProvider.overrideWithValue(_FlashDisks()),
            emmcBackupManifestsProvider.overrideWith((_) async => const []),
            emmcBackupImageCandidatesProvider.overrideWith(
              (_) async => [
                EmmcBackupImageCandidate(
                  imagePath: r'C:\Deckhand\deckhand-cli-backup.img',
                  imageBytes: 32 * 1024 * 1024 * 1024,
                  modifiedAt: DateTime(2026, 5, 4),
                  inferredProfileId: null,
                ),
              ],
            ),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      expect(
        find.textContaining('Complete backup already exists'),
        findsOneWidget,
      );
      expect(
        find.textContaining(r'C:\Deckhand\deckhand-cli-backup.img'),
        findsOneWidget,
      );
      expect(find.text('Back up the disk first'), findsNothing);
      expect(find.text('START BACKUP'), findsNothing);
    });

    testWidgets('FlashConfirmScreen waits for selected disk before rendering', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = stubWizardController(profileJson: _profileJson());
      await controller.loadProfile('test-printer');
      await controller.setDecision('flash.disk', 'disk-emmc');
      await controller.setDecision('flash.os', 'debian-bookworm');
      final flash = _PendingFlashDisks();

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const FlashConfirmScreen(),
          initialLocation: '/flash-confirm',
          extraOverrides: [flashServiceProvider.overrideWithValue(flash)],
        ),
      );
      await tester.pump();

      expect(find.textContaining('Loading selected disk'), findsOneWidget);
      expect(find.textContaining('<no disk>'), findsNothing);
      expect(find.text('Back up the disk first'), findsNothing);
      expect(find.text("Back, don't wipe"), findsOneWidget);

      flash.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      expect(find.textContaining('Loading selected disk'), findsNothing);
      expect(find.text('Printer eMMC'), findsWidgets);
    });

    testWidgets(
      'FlashConfirmScreen waits for backup records before recommending backup',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final controller = stubWizardController(profileJson: _profileJson());
        await controller.loadProfile('test-printer');
        await controller.setDecision('flash.disk', 'disk-emmc');
        await controller.setDecision('flash.os', 'debian-bookworm');
        final manifests = Completer<List<EmmcBackupManifest>>();
        final candidates = Completer<List<EmmcBackupImageCandidate>>();

        await tester.pumpWidget(
          testHarness(
            controller: controller,
            child: const FlashConfirmScreen(),
            initialLocation: '/flash-confirm',
            extraOverrides: [
              flashServiceProvider.overrideWithValue(_FlashDisks()),
              emmcBackupManifestsProvider.overrideWith((_) => manifests.future),
              emmcBackupImageCandidatesProvider.overrideWith(
                (_) => candidates.future,
              ),
            ],
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.textContaining('Checking backup records'), findsOneWidget);
        expect(find.text('Back up the disk first'), findsNothing);
        expect(find.text('TARGET DISK — WILL BE ERASED'), findsNothing);
        expect(find.text("Back, don't wipe"), findsOneWidget);

        manifests.complete(const []);
        candidates.complete(const []);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump();

        expect(find.textContaining('Checking backup records'), findsNothing);
        expect(find.text('Back up the disk first'), findsOneWidget);
        expect(find.text('TARGET DISK — WILL BE ERASED'), findsOneWidget);
      },
    );

    testWidgets('FlashConfirmScreen confirms wipe with a modal', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = stubWizardController(profileJson: _profileJson());
      await controller.loadProfile('test-printer');
      await controller.setDecision('flash.disk', 'disk-emmc');
      await controller.setDecision('flash.os', 'debian-bookworm');

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const FlashConfirmScreen(),
          initialLocation: '/flash-confirm',
          extraOverrides: [
            flashServiceProvider.overrideWithValue(_FlashDisks()),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'disk-emmc');
      await tester.pump();
      expect(find.text('EXPECTED: Printer eMMC'), findsOneWidget);
      await tester.ensureVisible(find.text('Wipe and flash'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Wipe and flash'));
      await tester.pumpAndSettle();
      expect(find.text('Confirm wipe and flash'), findsNothing);
      expect(controller.state.flow, WizardFlow.none);

      await tester.enterText(find.byType(TextField), 'Printer eMMC');
      await tester.pump();
      expect(find.text('MATCH · WIPE ARMED'), findsOneWidget);
      expect(find.text('Hold to wipe and flash'), findsNothing);
      await tester.ensureVisible(find.text('Wipe and flash'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Wipe and flash'));
      await tester.pumpAndSettle();
      expect(find.text('Confirm wipe and flash'), findsOneWidget);
      expect(find.textContaining('Printer eMMC'), findsWidgets);
      expect(controller.state.flow, WizardFlow.none);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Confirm wipe and flash'), findsNothing);
      expect(controller.state.flow, WizardFlow.none);

      await tester.tap(find.text('Wipe and flash'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Wipe and flash now'));
      await tester.pump();

      expect(controller.state.flow, WizardFlow.freshFlash);
    });
  });
}

Map<String, dynamic> _profileJson() => testProfileJson(
  os: {
    'fresh_install_options': [
      {
        'id': 'debian-trixie',
        'display_name': 'Debian 13 preview',
        'url': 'https://example.com/trixie.img',
        'sha256':
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        'size_bytes_approx': 10 * 1024 * 1024 * 1024,
        'recommended': false,
      },
      {
        'id': 'debian-bookworm',
        'display_name': 'Debian 12 stable',
        'url': 'https://example.com/bookworm.img',
        'sha256':
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'size_bytes_approx': 8 * 1024 * 1024 * 1024,
        'recommended': true,
      },
    ],
  },
);

class _FlashDisks implements FlashService {
  @override
  Future<List<DiskInfo>> listDisks() async => const [
    DiskInfo(
      id: 'disk-system',
      path: r'\\.\PhysicalDrive0',
      sizeBytes: 512 * 1024 * 1024 * 1024,
      bus: 'NVMe',
      model: 'Host NVMe',
      removable: false,
      partitions: [
        PartitionInfo(
          index: 1,
          sizeBytes: 512 * 1024 * 1024,
          filesystem: 'ntfs',
          mountpoint: 'C:',
        ),
      ],
    ),
    DiskInfo(
      id: 'disk-emmc',
      path: r'\\.\PhysicalDrive3',
      sizeBytes: 32 * 1024 * 1024 * 1024,
      bus: 'USB',
      model: 'Printer eMMC',
      removable: true,
      partitions: [
        PartitionInfo(
          index: 1,
          sizeBytes: 512 * 1024 * 1024,
          filesystem: 'fat32',
          mountpoint: 'E:',
        ),
        PartitionInfo(
          index: 2,
          sizeBytes: 31 * 1024 * 1024 * 1024,
          filesystem: 'ext4',
        ),
      ],
    ),
  ];

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

class _PendingFlashDisks extends _FlashDisks {
  final _completer = Completer<List<DiskInfo>>();

  void complete() => _completer.complete(super.listDisks());

  @override
  Future<List<DiskInfo>> listDisks() => _completer.future;
}
