import 'dart:async';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/providers.dart';
import 'package:deckhand_ui/src/screens/emmc_backup_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const EmmcBackupScreen(),
          initialLocation: '/snapshot',
          extraOverrides: [
            flashServiceProvider.overrideWithValue(_OneDiskFlash()),
            elevatedHelperServiceProvider.overrideWithValue(helper),
            securityServiceProvider.overrideWithValue(security),
            emmcBackupsDirProvider.overrideWithValue(
              '/deckhand/state/emmc-backups',
            ),
          ],
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Back up this disk'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(security.consumed, [
        ('read-token-0123456789abcdef', 'disks.read_image'),
      ]);
      expect(helper.readCalls, 1);
      expect(helper.lastOutputPath, startsWith('/deckhand/state/emmc-backups'));
      expect(helper.lastOutputPath, endsWith('.img'));
    });

    testWidgets('does not launch helper when token consumption fails', (
      tester,
    ) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await controller.setDecision('flash.disk', 'disk-1');
      final security = _RecordingSecurity(consumeResult: false);
      final helper = _RecordingElevatedHelper();

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const EmmcBackupScreen(),
          initialLocation: '/snapshot',
          extraOverrides: [
            flashServiceProvider.overrideWithValue(_OneDiskFlash()),
            elevatedHelperServiceProvider.overrideWithValue(helper),
            securityServiceProvider.overrideWithValue(security),
            emmcBackupsDirProvider.overrideWithValue(
              '/deckhand/state/emmc-backups',
            ),
          ],
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Back up this disk'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(security.consumed, [
        ('read-token-0123456789abcdef', 'disks.read_image'),
      ]);
      expect(helper.readCalls, 0);
      expect(
        find.textContaining('confirmation token was rejected'),
        findsWidgets,
      );
    });

    testWidgets(
      'inherited disk decision cannot start backup until enumeration confirms it',
      (tester) async {
        final controller = stubWizardController(profileJson: testProfileJson());
        await controller.loadProfile('test-printer');
        await controller.setDecision('flash.disk', 'missing-disk');

        await tester.pumpWidget(
          testHarness(
            controller: controller,
            child: const EmmcBackupScreen(),
            initialLocation: '/snapshot',
            extraOverrides: [
              flashServiceProvider.overrideWithValue(_NoDiskFlash()),
              emmcBackupsDirProvider.overrideWithValue(
                '/deckhand/state/emmc-backups',
              ),
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
  });
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

  @override
  Stream<FlashProgress> readImage({
    required String diskId,
    required String outputPath,
    required String confirmationToken,
    int totalBytes = 0,
  }) {
    readCalls++;
    lastOutputPath = outputPath;
    return Stream.value(
      FlashProgress(
        bytesDone: totalBytes,
        bytesTotal: totalBytes,
        phase: FlashPhase.done,
        message: 'ok',
      ),
    );
  }

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
  );

  @override
  bool consumeToken(String value, String operation) {
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
