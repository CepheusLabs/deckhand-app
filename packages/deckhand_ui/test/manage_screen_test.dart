import 'dart:async';
import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/providers.dart';
import 'package:deckhand_ui/src/router.dart';
import 'package:deckhand_ui/src/screens/manage_screen.dart';
import 'package:deckhand_ui/src/theming/deckhand_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

  testWidgets('status tab copies saved printer ssh user and port', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = stubWizardController(profileJson: testProfileJson());
    await controller.restore(
      const WizardState(
        profileId: 'test-printer',
        decisions: {},
        currentStep: 'manage',
        flow: WizardFlow.none,
        sshHost: '192.168.1.51',
        sshPort: 2222,
        sshUser: 'mks',
      ),
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

    await tester.tap(find.widgetWithText(OutlinedButton, 'Copy SSH command'));
    await tester.pump();

    expect(clipboardWrites, contains('ssh -p 2222 mks@192.168.1.51'));
  });

  testWidgets('backup tab uses a direct eMMC backup action label', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = stubWizardController(profileJson: testProfileJson());
    await controller.loadProfile('test-printer');

    await tester.pumpWidget(
      testHarness(
        controller: controller,
        child: const ManageScreen(),
        initialLocation: '/manage',
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Backup').first);
    await tester.pump();

    expect(find.widgetWithText(FilledButton, 'Back up eMMC'), findsOneWidget);
    expect(find.text('Open backup flow'), findsNothing);
  });

  testWidgets('manage screen uses a left-side Back footer action', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = stubWizardController(profileJson: testProfileJson());
    await controller.loadProfile('test-printer');

    await tester.pumpWidget(
      testHarness(
        controller: controller,
        child: const ManageScreen(),
        initialLocation: '/manage',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(OutlinedButton, 'Back'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Back'), findsNothing);
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
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('BACKUP IMAGE'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Continue to target'));
    await tester.pump();
    expect(find.text('TARGET EMMC'), findsOneWidget);
    expect(find.textContaining('Generic STORAGE DEVICE'), findsWidgets);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Review restore'),
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
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Restore an eMMC backup.'), findsOneWidget);
    expect(find.text('BACKUP IMAGE'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Back'), findsOneWidget);
    expect(find.text('Done'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Continue to target'));
    await tester.pump();
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
    expect(find.widgetWithText(FilledButton, 'Create eMMC backup'), findsOne);
    expect(find.text('Open backup flow'), findsNothing);
    expect(find.textContaining(r'C:\Deckhand\emmc-backups'), findsOneWidget);
  });

  testWidgets('restore backup shortcut returns to restore after cancel', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = stubWizardController(profileJson: testProfileJson());
    await controller.loadProfile('test-printer');
    final router = buildDeckhandRouter();
    router.go('/emmc-restore');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...overrideForController(controller),
          deckhandSettingsProvider.overrideWithValue(
            DeckhandSettings(path: '<memory>'),
          ),
          emmcBackupManifestsProvider.overrideWith((ref) async => const []),
          emmcBackupImageCandidatesProvider.overrideWith(
            (ref) async => const [],
          ),
          emmcBackupsDirProvider.overrideWithValue(r'C:\Deckhand\emmc-backups'),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          theme: DeckhandTheme.light(),
          darkTheme: DeckhandTheme.dark(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final createBackup = find.widgetWithText(
      FilledButton,
      'Create eMMC backup',
    );
    await tester.ensureVisible(createBackup);
    await tester.tap(createBackup);
    await tester.pumpAndSettle();
    expect(find.text('Back up the eMMC now.'), findsOneWidget);

    final cancel = find.text('Cancel');
    await tester.ensureVisible(cancel);
    await tester.tap(cancel);
    await tester.pumpAndSettle();

    expect(find.text('Restore an eMMC backup.'), findsOneWidget);
    expect(find.text('Save your current configuration.'), findsNothing);
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
    expect(find.textContaining('Unindexed image'), findsWidgets);

    await tester.tap(find.widgetWithText(FilledButton, 'Continue to target'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Generic STORAGE DEVICE'), findsWidgets);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Review restore'),
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

    await tester.tap(find.widgetWithText(FilledButton, 'Continue to target'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Generic STORAGE DEVICE'), findsWidgets);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Review restore'),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('restore target step hides non-removable disks by default', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const removable = DiskInfo(
      id: 'PhysicalDrive3',
      path: r'\\.\PHYSICALDRIVE3',
      sizeBytes: 8 * 1024 * 1024,
      bus: 'USB',
      model: 'Generic STORAGE DEVICE',
      removable: true,
      partitions: [],
    );
    const internal = DiskInfo(
      id: 'PhysicalDrive0',
      path: r'\\.\PHYSICALDRIVE0',
      sizeBytes: 1024 * 1024 * 1024 * 1024,
      bus: 'NVMe',
      model: 'Samsung SSD 970 EVO Plus 1TB',
      removable: false,
      partitions: [],
    );
    final candidate = EmmcBackupImageCandidate(
      imagePath: r'C:\Deckhand\emmc-backups\restore.img',
      imageBytes: removable.sizeBytes,
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
            (ref) async => [candidate],
          ),
          flashServiceProvider.overrideWithValue(
            _RestoreFlash(
              disks: [internal, removable],
              sha256Value:
                  'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
            ),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.widgetWithText(FilledButton, 'Continue to target'));
    await tester.pump();

    expect(find.text('TARGET EMMC'), findsOneWidget);
    expect(find.textContaining('Generic STORAGE DEVICE'), findsWidgets);
    expect(find.textContaining('Samsung SSD'), findsNothing);
    expect(find.textContaining('1 disk hidden'), findsOneWidget);
  });

  testWidgets('restore target step hides fixed-bus disks even if removable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const adapter = DiskInfo(
      id: 'PhysicalDrive3',
      path: r'\\.\PHYSICALDRIVE3',
      sizeBytes: 8 * 1024 * 1024,
      bus: 'USB',
      model: 'Generic STORAGE DEVICE',
      removable: true,
      partitions: [],
    );
    const nvme = DiskInfo(
      id: 'PhysicalDrive0',
      path: r'\\.\PHYSICALDRIVE0',
      sizeBytes: 1024 * 1024 * 1024 * 1024,
      bus: 'NVMe',
      model: 'Samsung SSD 970 EVO Plus 1TB',
      removable: true,
      partitions: [],
    );
    final candidate = EmmcBackupImageCandidate(
      imagePath: r'C:\Deckhand\emmc-backups\restore.img',
      imageBytes: adapter.sizeBytes,
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
            (ref) async => [candidate],
          ),
          flashServiceProvider.overrideWithValue(
            _RestoreFlash(
              disks: [nvme, adapter],
              sha256Value:
                  'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
            ),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.widgetWithText(FilledButton, 'Continue to target'));
    await tester.pump();

    expect(find.text('TARGET EMMC'), findsOneWidget);
    expect(find.textContaining('Generic STORAGE DEVICE'), findsWidgets);
    expect(find.textContaining('Samsung SSD'), findsNothing);
    expect(find.textContaining('1 disk hidden'), findsOneWidget);
  });

  testWidgets('restore target step keeps unknown-bus storage adapters', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const adapter = DiskInfo(
      id: 'PhysicalDrive3',
      path: r'\\.\PHYSICALDRIVE3',
      sizeBytes: 8 * 1024 * 1024,
      bus: 'Unknown',
      model: 'Generic STORAGE DEVICE USB Device',
      removable: true,
      partitions: [],
    );
    final candidate = EmmcBackupImageCandidate(
      imagePath: r'C:\Deckhand\emmc-backups\restore.img',
      imageBytes: adapter.sizeBytes,
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
            (ref) async => [candidate],
          ),
          flashServiceProvider.overrideWithValue(
            _RestoreFlash(
              disks: [adapter],
              sha256Value:
                  'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
            ),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.widgetWithText(FilledButton, 'Continue to target'));
    await tester.pump();
    await tester.pump();

    expect(find.text('TARGET EMMC'), findsOneWidget);
    expect(
      find.textContaining('Generic STORAGE DEVICE USB Device'),
      findsWidgets,
    );
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Review restore'),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('restore view groups backups and collapses duplicate hashes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const sha =
        'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
    const disk = DiskInfo(
      id: 'PhysicalDrive3',
      path: r'\\.\PHYSICALDRIVE3',
      sizeBytes: 4096,
      bus: 'USB',
      model: 'Generic STORAGE DEVICE',
      removable: true,
      partitions: [],
    );
    final older = EmmcBackupManifest.create(
      profileId: 'phrozen-arco',
      imagePath: r'C:\Deckhand\emmc-backups\phrozen-arco\old\emmc.img',
      imageBytes: 4096,
      imageSha256: sha,
      disk: disk,
      deckhandVersion: 'test',
      createdAt: DateTime.utc(2026, 5, 3, 12),
    );
    final newer = EmmcBackupManifest.create(
      profileId: 'phrozen-arco',
      imagePath: r'C:\Deckhand\emmc-backups\phrozen-arco\new\emmc.img',
      imageBytes: 4096,
      imageSha256: sha,
      disk: disk,
      deckhandVersion: 'test',
      createdAt: DateTime.utc(2026, 5, 4, 12),
    );
    final partial = EmmcBackupImageCandidate(
      imagePath: r'C:\Deckhand\emmc-backups\phrozen-arco\partial\emmc.img',
      imageBytes: 2048,
      modifiedAt: DateTime.utc(2026, 5, 5, 12),
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
          emmcBackupManifestsProvider.overrideWith(
            (ref) async => [older, newer],
          ),
          emmcBackupImageCandidatesProvider.overrideWith(
            (ref) async => [partial],
          ),
          flashServiceProvider.overrideWithValue(
            _RestoreFlash(disks: [disk], sha256Value: sha),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('PHROZEN-ARCO'), findsOneWidget);
    expect(find.textContaining('1 duplicate hidden'), findsOneWidget);
    expect(
      find.textContaining('Duplicate copies kept on disk:'),
      findsOneWidget,
    );
    expect(find.textContaining(r'phrozen-arco\old\emmc.img'), findsOneWidget);
    expect(find.textContaining('Indexed full-disk backup'), findsOneWidget);
    expect(find.textContaining('Unindexed partial image'), findsOneWidget);
  });

  testWidgets(
    'restore defaults to a full backup before a newer partial image',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      const sha =
          '1212121212121212121212121212121212121212121212121212121212121212';
      const disk = DiskInfo(
        id: 'PhysicalDrive3',
        path: r'\\.\PHYSICALDRIVE3',
        sizeBytes: 4096,
        bus: 'USB',
        model: 'Generic STORAGE DEVICE',
        removable: true,
        partitions: [],
      );
      final full = EmmcBackupManifest.create(
        profileId: 'phrozen-arco',
        imagePath: r'C:\Deckhand\emmc-backups\phrozen-arco\full\emmc.img',
        imageBytes: 4096,
        imageSha256: sha,
        disk: disk,
        deckhandVersion: 'test',
        createdAt: DateTime.utc(2026, 5, 4, 12),
      );
      final partial = EmmcBackupImageCandidate(
        imagePath: r'C:\Deckhand\emmc-backups\phrozen-arco\partial\emmc.img',
        imageBytes: 2048,
        modifiedAt: DateTime.utc(2026, 5, 5, 12),
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
            emmcBackupManifestsProvider.overrideWith((ref) async => [full]),
            emmcBackupImageCandidatesProvider.overrideWith(
              (ref) async => [partial],
            ),
            flashServiceProvider.overrideWithValue(
              _RestoreFlash(disks: [disk], sha256Value: sha),
            ),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      await tester.tap(find.widgetWithText(FilledButton, 'Continue to target'));
      await tester.pump();

      expect(find.textContaining('Indexed full-disk backup'), findsOneWidget);
      expect(find.textContaining('Unindexed partial image'), findsNothing);
    },
  );

  testWidgets('restore flow offers indexing for unindexed images', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const disk = DiskInfo(
      id: 'PhysicalDrive3',
      path: r'\\.\PHYSICALDRIVE3',
      sizeBytes: 4096,
      bus: 'USB',
      model: 'Generic STORAGE DEVICE',
      removable: true,
      partitions: [],
    );
    final candidate = EmmcBackupImageCandidate(
      imagePath: r'C:\Deckhand\emmc-backups\phrozen-arco\image\emmc.img',
      imageBytes: 4096,
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
            (ref) async => [candidate],
          ),
          flashServiceProvider.overrideWithValue(
            _RestoreFlash(disks: [disk], sha256Value: 'f' * 64),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.widgetWithText(FilledButton, 'Continue to target'));
    await tester.pump();
    expect(find.text('Unindexed image'), findsWidgets);
    final button = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Verify and index'),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('restore flow uses backup target confirmation then progress', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const sha =
        '9999999999999999999999999999999999999999999999999999999999999999';
    const disk = DiskInfo(
      id: 'PhysicalDrive3',
      path: r'\\.\PHYSICALDRIVE3',
      sizeBytes: 4096,
      bus: 'USB',
      model: 'Generic STORAGE DEVICE',
      removable: true,
      partitions: [],
    );
    final manifest = EmmcBackupManifest.create(
      profileId: 'phrozen-arco',
      imagePath: r'C:\Deckhand\emmc-backups\phrozen-arco\image\emmc.img',
      imageBytes: 4096,
      imageSha256: sha,
      disk: disk,
      deckhandVersion: 'test',
      createdAt: DateTime.utc(2026, 5, 4, 12),
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
          emmcBackupImageCandidatesProvider.overrideWith(
            (ref) async => const [],
          ),
          flashServiceProvider.overrideWithValue(
            _RestoreFlash(disks: [disk], sha256Value: sha),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.widgetWithText(FilledButton, 'Continue to target'));
    await tester.pump();
    await tester.pump();
    expect(find.text('TARGET EMMC'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Review restore'));
    await tester.pump();
    await tester.pump();
    expect(find.text('RESTORE CONFIRMATION'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Restore backup'));
    await tester.pump();
    expect(find.text('Erase and restore eMMC?'), findsOneWidget);
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
