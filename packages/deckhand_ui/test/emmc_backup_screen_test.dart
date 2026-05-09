import 'dart:async';
import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/providers.dart';
import 'package:deckhand_ui/src/screens/emmc_backup_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'helpers.dart';

void main() {
  group('EmmcBackupScreen', () {
    testWidgets('consumes read-image token before launching helper', (
      tester,
    ) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await controller.setDecision('flash.disk', 'disk-1');
      final security = _RecordingSecurity(consumeResult: true);
      final helper = _RecordingElevatedHelper();
      final backupRoot = _createTempBackupRoot();

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const EmmcBackupScreen(),
          initialLocation: '/snapshot',
          extraOverrides: [
            flashServiceProvider.overrideWithValue(_OneDiskFlash()),
            elevatedHelperServiceProvider.overrideWithValue(helper),
            securityServiceProvider.overrideWithValue(security),
            emmcBackupsDirProvider.overrideWithValue(backupRoot),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await _tapStartBackup(tester);
      await tester.pump(const Duration(milliseconds: 50));

      expect(security.consumed, [
        ('read-token-0123456789abcdef', 'disks.read_image'),
      ]);
      expect(helper.readCalls, 1);
      expect(helper.lastOutputPath, startsWith(backupRoot));
      expect(
        p.basename(p.dirname(p.dirname(helper.lastOutputPath!))),
        'test-printer',
      );
      expect(p.basename(helper.lastOutputPath!), 'emmc.img');
      expect(helper.lastOutputPath, endsWith('.img'));
      expect(helper.lastOutputRoot, backupRoot);
    });

    testWidgets('keeps destination picker enabled with elevated helper', (
      tester,
    ) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await controller.setDecision('flash.disk', 'disk-1');
      final backupRoot = _createTempBackupRoot();

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const EmmcBackupScreen(),
          initialLocation: '/snapshot',
          extraOverrides: [
            flashServiceProvider.overrideWithValue(_OneDiskFlash()),
            elevatedHelperServiceProvider.overrideWithValue(
              _RecordingElevatedHelper(),
            ),
            emmcBackupsDirProvider.overrideWithValue(backupRoot),
          ],
        ),
      );
      await tester.pumpAndSettle();

      final change = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Change…'),
      );
      expect(change.onPressed, isNotNull);
    });

    testWidgets('tells the user when a full-size backup already exists', (
      tester,
    ) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await controller.setDecision('flash.disk', 'disk-1');
      final backupRoot = _createTempBackupRoot();
      final candidatePath = p.join(backupRoot, 'test.img');

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const EmmcBackupScreen(),
          initialLocation: '/snapshot',
          extraOverrides: [
            flashServiceProvider.overrideWithValue(_OneDiskFlash()),
            elevatedHelperServiceProvider.overrideWithValue(
              _RecordingElevatedHelper(),
            ),
            emmcBackupsDirProvider.overrideWithValue(backupRoot),
            emmcBackupImageCandidatesProvider.overrideWith(
              (_) async => [
                EmmcBackupImageCandidate(
                  imagePath: candidatePath,
                  imageBytes: 4096,
                  modifiedAt: DateTime(2026, 5, 4),
                  inferredProfileId: 'test-printer',
                ),
              ],
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Complete backup already exists'),
        findsOneWidget,
      );
      expect(find.textContaining(candidatePath), findsOneWidget);
    });

    testWidgets('allows cancel while a backup is copying', (tester) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await controller.setDecision('flash.disk', 'disk-1');
      final helper = _StreamingElevatedHelper();
      final backupRoot = _createTempBackupRoot();

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const EmmcBackupScreen(),
          initialLocation: '/snapshot',
          extraOverrides: [
            flashServiceProvider.overrideWithValue(_OneDiskFlash()),
            elevatedHelperServiceProvider.overrideWithValue(helper),
            emmcBackupsDirProvider.overrideWithValue(backupRoot),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await _tapStartBackup(tester);
      helper.add(
        const FlashProgress(
          bytesDone: 1024,
          bytesTotal: 4096,
          phase: FlashPhase.writing,
        ),
      );
      await tester.pump();

      final cancel = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Cancel'),
      );
      expect(cancel.onPressed, isNotNull);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 750));

      expect(helper.canceled, isTrue);
      expect(find.textContaining('Backup canceled'), findsWidgets);
    });

    testWidgets('shows copy speed and ETA after progress samples', (
      tester,
    ) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await controller.setDecision('flash.disk', 'disk-1');
      final helper = _StreamingElevatedHelper();
      final backupRoot = _createTempBackupRoot();

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const EmmcBackupScreen(),
          initialLocation: '/snapshot',
          extraOverrides: [
            flashServiceProvider.overrideWithValue(_OneDiskFlash()),
            elevatedHelperServiceProvider.overrideWithValue(helper),
            emmcBackupsDirProvider.overrideWithValue(backupRoot),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await _tapStartBackup(tester);
      helper.add(
        const FlashProgress(
          bytesDone: 1024,
          bytesTotal: 4096,
          phase: FlashPhase.writing,
        ),
      );
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 650)),
      );
      helper.add(
        const FlashProgress(
          bytesDone: 2048,
          bytesTotal: 4096,
          phase: FlashPhase.writing,
        ),
      );
      await tester.pump();

      expect(find.textContaining('KiB/s'), findsOneWidget);
      expect(find.textContaining('ETA'), findsOneWidget);
    });

    testWidgets('progress detail uses the friendly disk label', (tester) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await controller.setDecision('flash.disk', 'disk-1');
      final helper = _StreamingElevatedHelper();
      final backupRoot = _createTempBackupRoot();

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const EmmcBackupScreen(),
          initialLocation: '/snapshot',
          extraOverrides: [
            flashServiceProvider.overrideWithValue(_OneDiskFlash()),
            elevatedHelperServiceProvider.overrideWithValue(helper),
            emmcBackupsDirProvider.overrideWithValue(backupRoot),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await _tapStartBackup(tester);
      helper.add(
        const FlashProgress(
          bytesDone: 0,
          bytesTotal: 4096,
          phase: FlashPhase.preparing,
          message: r'\\.\PHYSICALDRIVE3',
        ),
      );
      await tester.pump();

      expect(find.textContaining('PHYSICALDRIVE3'), findsNothing);
      expect(find.textContaining('Test eMMC'), findsWidgets);
    });

    testWidgets('backup helper failures hide raw disk ids', (tester) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await controller.setDecision('flash.disk', 'disk-1');
      final helper = _StreamingElevatedHelper();
      final backupRoot = _createTempBackupRoot();

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const EmmcBackupScreen(),
          initialLocation: '/snapshot',
          extraOverrides: [
            flashServiceProvider.overrideWithValue(_OneDiskFlash()),
            elevatedHelperServiceProvider.overrideWithValue(helper),
            emmcBackupsDirProvider.overrideWithValue(backupRoot),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await _tapStartBackup(tester);
      helper.add(
        const FlashProgress(
          bytesDone: 1024,
          bytesTotal: 4096,
          phase: FlashPhase.failed,
          message: r'write \\.\PHYSICALDRIVE3: Access is denied.',
        ),
      );
      await tester.pump();

      expect(find.textContaining('Windows denied raw-disk access'), findsOne);
      expect(find.textContaining('PHYSICALDRIVE3'), findsNothing);
    });

    testWidgets('successful backup writes an eMMC manifest', (tester) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await controller.setDecision('flash.disk', 'disk-1');
      final helper = _RecordingElevatedHelper();
      EmmcBackupManifest? writtenManifest;
      final backupRoot = _createTempBackupRoot();

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const EmmcBackupScreen(),
          initialLocation: '/snapshot',
          extraOverrides: [
            flashServiceProvider.overrideWithValue(_OneDiskFlash()),
            elevatedHelperServiceProvider.overrideWithValue(helper),
            emmcBackupsDirProvider.overrideWithValue(backupRoot),
            emmcBackupManifestWriterProvider.overrideWithValue((
              manifest,
            ) async {
              writtenManifest = manifest;
              return emmcBackupManifestPath(manifest.imagePath);
            }),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await _tapStartBackup(tester);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('Continue'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      final manifest = writtenManifest;

      expect(manifest, isNotNull);
      expect(manifest!.profileId, 'test-printer');
      expect(manifest.imagePath, helper.lastOutputPath);
      expect(manifest.imageBytes, 4096);
      expect(manifest.imageSha256, 'a' * 64);
      expect(manifest.disk.model, 'Test eMMC');
    });

    testWidgets('does not launch helper when token consumption fails', (
      tester,
    ) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await controller.setDecision('flash.disk', 'disk-1');
      final security = _RecordingSecurity(consumeResult: false);
      final helper = _RecordingElevatedHelper();
      final backupRoot = _createTempBackupRoot();

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const EmmcBackupScreen(),
          initialLocation: '/snapshot',
          extraOverrides: [
            flashServiceProvider.overrideWithValue(_OneDiskFlash()),
            elevatedHelperServiceProvider.overrideWithValue(helper),
            securityServiceProvider.overrideWithValue(security),
            emmcBackupsDirProvider.overrideWithValue(backupRoot),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await _tapStartBackup(tester);
      await tester.pump(const Duration(milliseconds: 50));

      expect(security.consumed, [
        ('read-token-0123456789abcdef', 'disks.read_image'),
      ]);
      expect(helper.readCalls, 0);
      expect(find.textContaining('Deckhand rejected'), findsWidgets);
    });

    testWidgets(
      'inherited disk decision cannot start backup until enumeration confirms it',
      (tester) async {
        final controller = stubWizardController(profileJson: testProfileJson());
        await controller.loadProfile('test-printer');
        await controller.setDecision('flash.disk', 'missing-disk');
        final backupRoot = _createTempBackupRoot();

        await tester.pumpWidget(
          testHarness(
            controller: controller,
            child: const EmmcBackupScreen(),
            initialLocation: '/snapshot',
            extraOverrides: [
              flashServiceProvider.overrideWithValue(_NoDiskFlash()),
              emmcBackupsDirProvider.overrideWithValue(backupRoot),
            ],
          ),
        );
        await tester.pumpAndSettle();

        final button = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Back up this disk'),
        );
        expect(button.onPressed, isNull);
      },
    );

    testWidgets('unresolved inherited disk never shows the raw id', (
      tester,
    ) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await controller.setDecision('flash.disk', 'PhysicalDrive3');
      final backupRoot = _createTempBackupRoot();

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const EmmcBackupScreen(),
          initialLocation: '/snapshot',
          extraOverrides: [
            flashServiceProvider.overrideWithValue(_NoDiskFlash()),
            emmcBackupsDirProvider.overrideWithValue(backupRoot),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Selected disk is no longer connected'), findsOneWidget);
      expect(find.text('PhysicalDrive3'), findsNothing);
    });
  });
}

String _createTempBackupRoot() {
  final dir = Directory.systemTemp.createTempSync('deckhand-emmc-backups-');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });
  return dir.path;
}

Future<void> _tapStartBackup(WidgetTester tester) async {
  await tester.tap(find.text('Back up this disk'));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await tester.pump();
}

class _OneDiskFlash implements FlashService {
  @override
  Future<List<DiskInfo>> listDisks() async => const [
    DiskInfo(
      id: 'disk-1',
      path: r'\\.\PhysicalDrive3',
      sizeBytes: 4096,
      bus: 'USB',
      model: 'Test eMMC',
      removable: true,
      partitions: [],
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

class _NoDiskFlash implements FlashService {
  @override
  Future<List<DiskInfo>> listDisks() async => const [];

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

class _RecordingElevatedHelper implements ElevatedHelperService {
  int readCalls = 0;
  String? lastOutputPath;
  String? lastOutputRoot;

  @override
  Stream<FlashProgress> readImage({
    required String diskId,
    required String outputPath,
    required String confirmationToken,
    int totalBytes = 0,
    String? outputRoot,
  }) {
    readCalls++;
    lastOutputPath = outputPath;
    lastOutputRoot = outputRoot;
    return Stream.value(
      FlashProgress(
        bytesDone: totalBytes,
        bytesTotal: totalBytes,
        phase: FlashPhase.done,
        message: 'a' * 64,
      ),
    );
  }

  @override
  Stream<FlashProgress> hashDevice({
    required String diskId,
    required String confirmationToken,
    int totalBytes = 0,
  }) => const Stream.empty();

  @override
  Stream<FlashProgress> writeImage({
    required String imagePath,
    required String diskId,
    required String confirmationToken,
    bool verifyAfterWrite = true,
    String? expectedSha256,
  }) => const Stream.empty();
}

class _StreamingElevatedHelper implements ElevatedHelperService {
  _StreamingElevatedHelper() {
    _controller = StreamController<FlashProgress>(
      onCancel: () {
        canceled = true;
      },
    );
  }

  late final StreamController<FlashProgress> _controller;
  bool canceled = false;

  void add(FlashProgress event) => _controller.add(event);

  @override
  Stream<FlashProgress> readImage({
    required String diskId,
    required String outputPath,
    required String confirmationToken,
    int totalBytes = 0,
    String? outputRoot,
  }) => _controller.stream;

  @override
  Stream<FlashProgress> hashDevice({
    required String diskId,
    required String confirmationToken,
    int totalBytes = 0,
  }) => const Stream.empty();

  @override
  Stream<FlashProgress> writeImage({
    required String imagePath,
    required String diskId,
    required String confirmationToken,
    bool verifyAfterWrite = true,
    String? expectedSha256,
  }) => const Stream.empty();
}

class _RecordingSecurity implements SecurityService {
  _RecordingSecurity({required this.consumeResult});

  final bool consumeResult;
  final consumed = <(String, String)>[];

  @override
  Future<ConfirmationToken> issueConfirmationToken({
    required String operation,
    required String target,
    Duration ttl = const Duration(seconds: 60),
  }) async => ConfirmationToken(
    value: 'read-token-0123456789abcdef',
    expiresAt: DateTime.now().add(ttl),
    operation: operation,
    target: target,
  );

  @override
  bool consumeToken(String value, String operation, {required String target}) {
    consumed.add((value, operation));
    return consumeResult;
  }

  @override
  Future<Map<String, bool>> requestHostApprovals(List<String> hosts) async => {
    for (final host in hosts) host: true,
  };

  @override
  Future<bool> isHostAllowed(String host) async => true;

  @override
  Future<void> approveHost(String host) async {}

  @override
  Future<void> revokeHost(String host) async {}

  @override
  Future<List<String>> listApprovedHosts() async => const [];

  @override
  Future<void> pinHostFingerprint({
    required String host,
    required String fingerprint,
  }) async {}

  @override
  Future<String?> pinnedHostFingerprint(String host) async => null;

  @override
  Future<void> forgetHostFingerprint(String host) async {}

  @override
  Future<Map<String, String>> listPinnedFingerprints() async => const {};

  @override
  Future<String?> getGitHubToken() async => null;

  @override
  Future<void> setGitHubToken(String? token) async {}

  @override
  Stream<EgressEvent> get egressEvents => const Stream.empty();

  @override
  void recordEgress(EgressEvent event) {}
}
