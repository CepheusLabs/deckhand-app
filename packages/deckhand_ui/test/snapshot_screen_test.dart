import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/providers.dart';
import 'package:deckhand_ui/src/screens/snapshot_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('SnapshotScreen', () {
    testWidgets('renders the no-paths copy when the profile declares none', (
      tester,
    ) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const SnapshotScreen(),
          initialLocation: '/snapshot',
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      // Heading is rendered.
      expect(
        find.textContaining('Save your current configuration'),
        findsWidgets,
      );
      // The "no paths declared" message reaches the user.
      expect(
        find.textContaining("doesn't declare any snapshot paths"),
        findsOneWidget,
      );
      // Restore strategy radio still appears so the user can pick a
      // default for any future profile that does declare paths.
      expect(find.text('Save as a separate backup'), findsOneWidget);
    });

    testWidgets('renders profile-declared paths with their helper text', (
      tester,
    ) async {
      final controller = stubWizardController(
        profileJson: {
          ...testProfileJson(),
          'stock_os': {
            'snapshot_paths': [
              {
                'id': 'config',
                'display_name': 'Printer config',
                'path': '~/printer_data/config',
                'default_selected': true,
                'helper_text': 'printer.cfg + macros',
              },
            ],
          },
        },
      );
      await controller.loadProfile('test-printer');
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const SnapshotScreen(),
          initialLocation: '/snapshot',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Printer config'), findsOneWidget);
      expect(find.text('printer.cfg + macros'), findsOneWidget);
      expect(find.textContaining('~/printer_data/config'), findsOneWidget);
    });

    testWidgets('requires live disk hash before trusting a matching backup', (
      tester,
    ) async {
      final manifest = EmmcBackupManifest.create(
        profileId: 'test-printer',
        imagePath: r'C:\Deckhand\backup.img',
        imageBytes: 4096,
        imageSha256: 'a' * 64,
        disk: _disk,
        deckhandVersion: 'dev',
      );

      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await controller.setDecision('flash.disk', 'disk-1');
      final helper = _HashingElevatedHelper('a' * 64);
      final security = _RecordingSecurity();

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const SnapshotScreen(),
          initialLocation: '/snapshot',
          extraOverrides: [
            flashServiceProvider.overrideWithValue(const _OneDiskFlash()),
            elevatedHelperServiceProvider.overrideWithValue(helper),
            securityServiceProvider.overrideWithValue(security),
            emmcBackupManifestsProvider.overrideWith((_) async => [manifest]),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      expect(find.textContaining('Matching eMMC backup found'), findsOneWidget);
      expect(find.text('Verify exact match'), findsOneWidget);
      var primary = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Snapshot and continue'),
      );
      expect(primary.onPressed, isNull);

      await tester.tap(find.text('Verify exact match'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      expect(find.textContaining('Exact eMMC backup verified'), findsOneWidget);
      primary = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Snapshot and continue'),
      );
      expect(primary.onPressed, isNotNull);
      expect(helper.hashCalls, 1);
      expect(security.consumed, [
        ('hash-token-0123456789abcdef', 'disks.hash_device'),
      ]);
    });

    testWidgets('surfaces and indexes full-size image candidates', (
      tester,
    ) async {
      final candidate = EmmcBackupImageCandidate(
        imagePath: r'C:\Deckhand\phrozen-arco-emmc-old.img',
        imageBytes: 4096,
        modifiedAt: DateTime(2026, 5, 4),
        inferredProfileId: 'test-printer',
      );
      EmmcBackupManifest? writtenManifest;

      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await controller.setDecision('flash.disk', 'disk-1');
      final helper = _HashingElevatedHelper('b' * 64);
      final security = _RecordingSecurity();

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const SnapshotScreen(),
          initialLocation: '/snapshot',
          extraOverrides: [
            flashServiceProvider.overrideWithValue(_OneDiskFlash('b' * 64)),
            elevatedHelperServiceProvider.overrideWithValue(helper),
            securityServiceProvider.overrideWithValue(security),
            emmcBackupManifestsProvider.overrideWith((_) async => const []),
            emmcBackupImageCandidatesProvider.overrideWith(
              (_) async => [candidate],
            ),
            emmcBackupManifestWriterProvider.overrideWithValue((
              manifest,
            ) async {
              writtenManifest = manifest;
              return emmcBackupManifestPath(manifest.imagePath);
            }),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      expect(find.textContaining('Complete eMMC image found'), findsOneWidget);
      expect(find.text('Verify exact match'), findsOneWidget);

      await tester.tap(find.text('Verify exact match'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      expect(find.textContaining('Exact eMMC backup verified'), findsOneWidget);
      expect(writtenManifest?.imagePath, candidate.imagePath);
      expect(writtenManifest?.imageSha256, 'b' * 64);
      expect(helper.hashCalls, 1);
    });
  });
}

const _disk = DiskInfo(
  id: 'disk-1',
  path: r'\\.\PhysicalDrive3',
  sizeBytes: 4096,
  bus: 'USB',
  model: 'Test eMMC',
  removable: true,
  partitions: [],
);

class _OneDiskFlash implements FlashService {
  const _OneDiskFlash([this.imageSha256 = '']);

  final String imageSha256;

  @override
  Future<List<DiskInfo>> listDisks() async => const [_disk];

  @override
  Future<FlashSafetyVerdict> safetyCheck({required String diskId}) async =>
      FlashSafetyVerdict(diskId: diskId, allowed: true);

  @override
  Stream<FlashProgress> readImage({
    required String diskId,
    required String outputPath,
  }) => const Stream.empty();

  @override
  Future<String> sha256(String path) async => imageSha256;

  @override
  Stream<FlashProgress> writeImage({
    required String imagePath,
    required String diskId,
    required String confirmationToken,
    bool verifyAfterWrite = true,
  }) => const Stream.empty();
}

class _HashingElevatedHelper implements ElevatedHelperService {
  _HashingElevatedHelper(this.sha256);

  final String sha256;
  int hashCalls = 0;

  @override
  Stream<FlashProgress> hashDevice({
    required String diskId,
    required String confirmationToken,
    int totalBytes = 0,
  }) {
    hashCalls++;
    return Stream.value(
      FlashProgress(
        bytesDone: totalBytes,
        bytesTotal: totalBytes,
        phase: FlashPhase.done,
        message: sha256,
      ),
    );
  }

  @override
  Stream<FlashProgress> readImage({
    required String diskId,
    required String outputPath,
    required String confirmationToken,
    int totalBytes = 0,
    String? outputRoot,
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
  final consumed = <(String, String)>[];

  @override
  Future<ConfirmationToken> issueConfirmationToken({
    required String operation,
    required String target,
    Duration ttl = const Duration(seconds: 60),
  }) async => ConfirmationToken(
    value: 'hash-token-0123456789abcdef',
    expiresAt: DateTime.now().add(ttl),
    operation: operation,
    target: target,
  );

  @override
  bool consumeToken(String value, String operation, {required String target}) {
    consumed.add((value, operation));
    return true;
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
