import 'dart:async';
import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('snapshot_archive step', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('deckhand-snapshot-');
    });
    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } on Object {
        /* best-effort */
      }
    });

    test('warns and skips when no archive service is wired', () async {
      final ssh = _FakeSsh();
      final controller = _build(profile: _profileWithSnapshot, ssh: ssh);
      await controller.loadProfile('p1');
      await controller.connectSsh(host: '127.0.0.1');
      controller.setFlow(WizardFlow.stockKeep);
      await controller.setDecision('snapshot.paths', ['cfg']);

      final warnings = <String>[];
      final sub = controller.events.listen((e) {
        if (e is StepWarning) warnings.add(e.message);
      });
      await controller.startExecution();
      await sub.cancel();

      expect(
        warnings.any((m) => m.contains('archive service not wired')),
        isTrue,
      );
      // No archive command should have been issued.
      expect(ssh.streamCommands, isEmpty);
    });

    test('warns and skips when the user selected nothing', () async {
      final archive = _FakeArchive();
      final controller = _build(
        profile: _profileWithSnapshot,
        ssh: _FakeSsh(),
        archive: archive,
        snapshotsDir: tmp.path,
      );
      await controller.loadProfile('p1');
      await controller.connectSsh(host: '127.0.0.1');
      controller.setFlow(WizardFlow.stockKeep);
      // No snapshot.paths decision.

      final warnings = <String>[];
      final sub = controller.events.listen((e) {
        if (e is StepWarning) warnings.add(e.message);
      });
      await controller.startExecution();
      await sub.cancel();
      expect(
        warnings.any((m) => m.contains('no snapshot paths selected')),
        isTrue,
      );
      expect(archive.captureCalls, isEmpty);
    });

    test('drops unknown ids with a warning, archives the rest', () async {
      final archive = _FakeArchive();
      final controller = _build(
        profile: _profileWithSnapshot,
        ssh: _FakeSsh(),
        archive: archive,
        snapshotsDir: tmp.path,
      );
      await controller.loadProfile('p1');
      await controller.connectSsh(host: '127.0.0.1');
      controller.setFlow(WizardFlow.stockKeep);
      await controller.setDecision('snapshot.paths', ['cfg', 'phantom-id']);

      final warnings = <String>[];
      final sub = controller.events.listen((e) {
        if (e is StepWarning) warnings.add(e.message);
      });
      await controller.startExecution();
      await sub.cancel();

      expect(warnings.any((m) => m.contains('phantom-id')), isTrue);
      // Archive ran with only the resolvable path.
      expect(archive.captureCalls, hasLength(1));
      expect(archive.captureCalls.single.paths, ['~/printer_data/config']);
    });

    test('records archive_path + archive_sha256 into wizard state', () async {
      final archive = _FakeArchive(
        progress: const [
          SnapshotProgress(bytesCaptured: 42, bytesEstimated: 42),
        ],
        sha: 'feedface',
      );
      final controller = _build(
        profile: _profileWithSnapshot,
        ssh: _FakeSsh(),
        archive: archive,
        snapshotsDir: tmp.path,
      );
      await controller.loadProfile('p1');
      await controller.connectSsh(host: '127.0.0.1');
      controller.setFlow(WizardFlow.stockKeep);
      await controller.setDecision('snapshot.paths', ['cfg']);

      await controller.startExecution();

      // The path is namespaced under <profile-id>-<ts>.tar.gz; we
      // assert the prefix shape (the timestamp is non-deterministic).
      final archivePath = controller.state.decisions['snapshot.archive_path'];
      expect(archivePath, isA<String>());
      expect(archivePath as String, contains(p.basename(tmp.path)));
      expect(archivePath, endsWith('.tar.gz'));
      expect(controller.state.decisions['snapshot.archive_sha256'], 'feedface');
    });
  });
}

WizardController _build({
  required Map<String, dynamic> profile,
  required SshService ssh,
  ArchiveService? archive,
  String? snapshotsDir,
}) {
  return WizardController(
    profiles: _StubProfileService(PrinterProfile.fromJson(profile)),
    ssh: ssh,
    flash: _StubFlash(),
    discovery: _StubDiscovery(),
    moonraker: const _StubMoonraker(),
    upstream: _StubUpstream(),
    security: _StubSecurity(),
    archive: archive,
    snapshotsDir: snapshotsDir,
  );
}

final Map<String, dynamic> _profileWithSnapshot = {
  'profile_id': 'p1',
  'profile_version': '0.1.0',
  'display_name': 'p1',
  'status': 'alpha',
  'manufacturer': 'Acme',
  'model': 'Robo',
  'os': {
    'fresh_install_options': [
      {'id': 'x', 'display_name': 'x', 'url': 'https://e/x'},
    ],
  },
  'ssh': {
    'default_port': 22,
    'default_credentials': [
      {'user': 'root', 'password': 'r'},
    ],
  },
  'stock_os': {
    'snapshot_paths': [
      {
        'id': 'cfg',
        'display_name': 'Printer config',
        'path': '~/printer_data/config',
        'default_selected': true,
      },
      {
        'id': 'extras',
        'display_name': 'Klippy extras',
        'path': '~/klippy_extras',
        'default_selected': false,
      },
    ],
  },
  'flows': {
    'stock_keep': {
      'enabled': true,
      'steps': [
        {'id': 'snap', 'kind': 'snapshot_archive'},
      ],
    },
  },
};

class _FakeArchive implements ArchiveService {
  _FakeArchive({this.progress = const [], this.sha = 'sha-stub'});

  final List<SnapshotProgress> progress;
  final String sha;
  final captureCalls = <_CaptureCall>[];

  @override
  Stream<SnapshotProgress> captureRemote({
    required SshSession session,
    required List<String> paths,
    required String archivePath,
  }) async* {
    captureCalls.add(_CaptureCall(paths: paths, archivePath: archivePath));
    for (final ev in progress) {
      yield ev;
    }
  }

  @override
  Future<RestoreResult> restoreRemote({
    required SshSession session,
    required String archivePath,
    required String destDir,
  }) async => const RestoreResult(restoredFiles: [], errors: []);

  @override
  Future<String> archiveSha256(String archivePath) async => sha;
}

class _CaptureCall {
  _CaptureCall({required this.paths, required this.archivePath});
  final List<String> paths;
  final String archivePath;
}

class _FakeSsh implements SshService {
  final streamCommands = <String>[];

  @override
  Future<SshSession> connect({
    required String host,
    int port = 22,
    required SshCredential credential,
    bool acceptHostKey = false,
    String? acceptedHostFingerprint,
  }) async => SshSession(id: 's', host: host, port: port, user: 'u');
  @override
  Future<SshSession> tryDefaults({
    required String host,
    int port = 22,
    required List<SshCredential> credentials,
    bool acceptHostKey = false,
    String? acceptedHostFingerprint,
  }) async => SshSession(id: 's', host: host, port: port, user: 'u');
  @override
  Future<SshCommandResult> run(
    SshSession session,
    String command, {
    Duration timeout = const Duration(seconds: 30),
    String? sudoPassword,
  }) async => const SshCommandResult(stdout: '', stderr: '', exitCode: 0);
  @override
  Stream<String> runStream(SshSession session, String command) async* {
    streamCommands.add(command);
  }

  @override
  Stream<String> runStreamMerged(SshSession session, String command) async* {
    streamCommands.add(command);
  }

  @override
  Future<int> upload(
    SshSession session,
    String localPath,
    String remotePath, {
    int? mode,
  }) async => 0;
  @override
  Future<int> download(
    SshSession session,
    String remotePath,
    String localPath,
  ) async => 0;
  @override
  Future<Map<String, int>> duPaths(
    SshSession session,
    List<String> paths,
  ) async => {for (final p in paths) p: 0};
  @override
  Future<void> disconnect(SshSession session) async {}
}

class _StubProfileService implements ProfileService {
  _StubProfileService(this.profile);
  final PrinterProfile profile;
  @override
  Future<ProfileCacheEntry> ensureCached({
    required String profileId,
    String? ref,
    bool force = false,
  }) async => ProfileCacheEntry(
    profileId: profileId,
    ref: ref ?? 'main',
    localPath: '.',
    resolvedSha: '',
  );
  @override
  Future<PrinterProfile> load(ProfileCacheEntry cacheEntry) async => profile;
  @override
  Future<ProfileRegistry> fetchRegistry({bool force = false}) async =>
      const ProfileRegistry(entries: []);
}

class _StubFlash implements FlashService {
  @override
  Future<List<DiskInfo>> listDisks() async => const [];
  @override
  Future<FlashSafetyVerdict> safetyCheck({required String diskId}) async =>
      FlashSafetyVerdict(diskId: diskId, allowed: true);
  @override
  Stream<FlashProgress> writeImage({
    required String imagePath,
    required String diskId,
    required String confirmationToken,
    bool verifyAfterWrite = true,
  }) => const Stream.empty();
  @override
  Stream<FlashProgress> readImage({
    required String diskId,
    required String outputPath,
  }) => const Stream.empty();
  @override
  Future<String> sha256(String path) async => '';
}

class _StubDiscovery implements DiscoveryService {
  @override
  Future<List<DiscoveredPrinter>> scanMdns({
    Duration timeout = const Duration(seconds: 5),
  }) async => const [];
  @override
  Future<List<DiscoveredPrinter>> scanCidr({
    required String cidr,
    int port = 7125,
    Duration timeout = const Duration(seconds: 5),
  }) async => const [];
  @override
  Future<bool> waitForSsh({
    required String host,
    int port = 22,
    Duration timeout = const Duration(minutes: 10),
  }) async => true;
}

class _StubMoonraker implements MoonrakerService {
  const _StubMoonraker();
  @override
  Future<KlippyInfo> info({required String host, int port = 7125}) async =>
      const KlippyInfo(
        state: 'ready',
        hostname: 'h',
        softwareVersion: '0',
        klippyState: 'ready',
      );
  @override
  Future<bool> isPrinting({required String host, int port = 7125}) async =>
      false;
  @override
  Future<Map<String, dynamic>> queryObjects({
    required String host,
    int port = 7125,
    required List<String> objects,
  }) async => const {};
  @override
  Future<void> runGCode({
    required String host,
    int port = 7125,
    required String script,
  }) async {}
  @override
  Future<List<String>> listObjects({
    required String host,
    int port = 7125,
  }) async => const [];
  @override
  Future<String?> fetchConfigFile({
    required String host,
    int port = 7125,
    required String filename,
  }) async => null;
}

class _StubUpstream implements UpstreamService {
  @override
  Future<UpstreamFetchResult> gitFetch({
    required String repoUrl,
    required String ref,
    required String destPath,
    int depth = 1,
  }) async => UpstreamFetchResult(localPath: destPath, resolvedRef: ref);
  @override
  Stream<OsDownloadProgress> osDownload({
    required String url,
    required String destPath,
    String? expectedSha256,
  }) => const Stream.empty();
  @override
  Future<UpstreamFetchResult> releaseFetch({
    required String repoSlug,
    required String assetPattern,
    required String destPath,
    required String expectedSha256,
    String? tag,
  }) async =>
      UpstreamFetchResult(localPath: destPath, resolvedRef: tag ?? 'latest');
}

class _StubSecurity implements SecurityService {
  @override
  Future<ConfirmationToken> issueConfirmationToken({
    required String operation,
    required String target,
    Duration ttl = const Duration(seconds: 60),
  }) async => ConfirmationToken(
    value: 'tok',
    expiresAt: DateTime.now().add(ttl),
    operation: operation,
    target: target,
  );
  @override
  bool consumeToken(String value, String operation, {required String target}) =>
      true;
  @override
  Future<bool> isHostAllowed(String host) async => true;
  @override
  Future<void> approveHost(String host) async {}
  @override
  Future<void> revokeHost(String host) async {}
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
  Future<List<String>> listApprovedHosts() async => const [];
  @override
  Future<String?> getGitHubToken() async => null;
  @override
  Future<void> setGitHubToken(String? token) async {}
  @override
  Future<Map<String, bool>> requestHostApprovals(List<String> hosts) async => {
    for (final h in hosts) h: true,
  };
  @override
  Stream<EgressEvent> get egressEvents => const Stream.empty();
  @override
  void recordEgress(EgressEvent event) {}
}
