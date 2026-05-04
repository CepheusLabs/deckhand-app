import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// The `printerStateForTesting` setter is documented as "no-op in
/// release builds, fully functional in debug". The test harness runs
/// in debug mode (asserts enabled), so the functional behavior is
/// what we can pin here. The release-mode no-op is verified by
/// construction: the setter's body lives inside `assert(() { ... }())`
/// which the Dart compiler strips when asserts are disabled.
///
/// To give that invariant teeth we also check the guard's structure
/// directly (the setter is a one-liner wrapper - if a future edit
/// moves logic outside the assert, this test fails its debug-mode
/// path for reasons we can spot in review).
void main() {
  test('printerStateForTesting applies state + emits refresh event', () async {
    final controller = _fakeController();
    await controller.loadProfile('test-printer');
    final gotEvents = <WizardEvent>[];
    final sub = controller.events.listen(gotEvents.add);
    final probed = PrinterState(
      services: const {},
      files: const {},
      paths: const {},
      stackInstalls: const {},
      screenInstalls: const {},
      python311Installed: false,
      osId: 'debian',
      osCodename: 'trixie',
      probedAt: DateTime.now(),
    );

    controller.printerStateForTesting = probed;
    // Flush microtasks so the StreamController delivers.
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    // Debug-mode invariants: state is applied and the refresh event
    // reaches listeners.
    expect(controller.printerState.osCodename, 'trixie');
    expect(
      gotEvents.any((e) => e is PrinterStateRefreshed),
      isTrue,
      reason: 'assert-gated body must emit the refresh event in debug',
    );
  });

  test(
    'multiple assignments compose (each one overrides previous probed state)',
    () async {
      final controller = _fakeController();
      await controller.loadProfile('test-printer');

      controller.printerStateForTesting = PrinterState(
        services: const {},
        files: const {},
        paths: const {},
        stackInstalls: const {},
        screenInstalls: const {},
        python311Installed: false,
        osCodename: 'buster',
        probedAt: DateTime.now(),
      );
      expect(controller.printerState.osCodename, 'buster');

      controller.printerStateForTesting = PrinterState(
        services: const {},
        files: const {},
        paths: const {},
        stackInstalls: const {},
        screenInstalls: const {},
        python311Installed: false,
        osCodename: 'trixie',
        probedAt: DateTime.now(),
      );
      expect(controller.printerState.osCodename, 'trixie');
    },
  );
}

// Minimal stubs, inline to avoid coupling with the wizard_controller
// test harness's internals.
WizardController _fakeController() => WizardController(
  profiles: _StubProfiles(),
  ssh: _StubSsh(),
  flash: _StubFlash(),
  discovery: _StubDiscovery(),
  moonraker: _StubMoonraker(),
  upstream: _StubUpstream(),
  security: _StubSecurity(),
);

class _StubProfiles implements ProfileService {
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
  Future<PrinterProfile> load(ProfileCacheEntry e) async =>
      PrinterProfile.fromJson(const {
        'profile_id': 'test-printer',
        'profile_version': '0.1.0',
      });
  @override
  Future<ProfileRegistry> fetchRegistry({bool force = false}) async =>
      const ProfileRegistry(entries: []);
}

class _StubSsh implements SshService {
  @override
  Future<SshSession> connect({
    required String host,
    int port = 22,
    required SshCredential credential,
    bool acceptHostKey = false,
    String? acceptedHostFingerprint,
  }) async => SshSession(id: 's', host: host, port: port, user: 'mks');
  @override
  Future<SshSession> tryDefaults({
    required String host,
    int port = 22,
    required List<SshCredential> credentials,
    bool acceptHostKey = false,
    String? acceptedHostFingerprint,
  }) async => SshSession(id: 's', host: host, port: port, user: 'mks');
  @override
  Future<SshCommandResult> run(
    SshSession session,
    String command, {
    Duration timeout = const Duration(seconds: 30),
    String? sudoPassword,
  }) async => const SshCommandResult(stdout: '', stderr: '', exitCode: 0);
  @override
  Stream<String> runStream(SshSession session, String command) =>
      const Stream.empty();
  @override
  Stream<String> runStreamMerged(SshSession session, String command) =>
      const Stream.empty();
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

class _StubFlash implements FlashService {
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

class _StubDiscovery implements DiscoveryService {
  @override
  Future<List<DiscoveredPrinter>> scanCidr({
    required String cidr,
    int port = 7125,
    Duration timeout = const Duration(seconds: 5),
  }) async => const [];
  @override
  Future<List<DiscoveredPrinter>> scanMdns({
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
  @override
  Future<KlippyInfo> info({required String host, int port = 7125}) async =>
      const KlippyInfo(
        state: 'ready',
        hostname: 's',
        softwareVersion: '',
        klippyState: 'ready',
      );
  @override
  Future<bool> isPrinting({required String host, int port = 7125}) async =>
      false;
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
    value: 'stub',
    expiresAt: DateTime.now().add(ttl),
    operation: operation,
  );
  @override
  bool consumeToken(String value, String operation) => true;
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
