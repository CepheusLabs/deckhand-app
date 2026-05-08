import 'dart:async';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/providers.dart';
import 'package:deckhand_ui/src/theming/deckhand_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Builds a `MaterialApp.router` with a trivial GoRouter so screens
/// that embed `DeckhandStepper` (which reads `GoRouterState`) can
/// mount in widget tests. The router points every route at [child]
/// so navigation calls in the screen don't throw either.
Widget testHarness({
  required WizardController controller,
  required Widget child,
  String initialLocation = '/',
  List<Override> extraOverrides = const [],
}) {
  final router = GoRouter(
    initialLocation: initialLocation,
    routes: [
      for (final path in const [
        '/',
        '/printers',
        '/pick-printer',
        '/connect',
        '/verify',
        '/choose-path',
        '/firmware',
        '/webui',
        '/kiauh',
        '/screen-choice',
        '/services',
        '/files',
        '/snapshot',
        '/emmc-backup',
        '/hardening',
        '/flash-target',
        '/choose-os',
        '/flash-confirm',
        '/first-boot',
        '/first-boot-setup',
        '/review',
        '/progress',
        '/done',
        '/manage',
        '/manage-emmc-backup',
        '/emmc-restore',
        '/settings',
      ])
        GoRoute(path: path, builder: (_, _) => child),
    ],
  );
  return ProviderScope(
    overrides: [
      ...overrideForController(controller),
      // Default in-memory settings so screens that read
      // deckhandSettingsProvider (verify_screen does, for prune
      // preferences) don't trip the _throwUnimplemented guard.
      deckhandSettingsProvider.overrideWithValue(
        DeckhandSettings(path: '<memory>'),
      ),
      // Per-test overrides win because they appear last (Riverpod
      // resolves overrides in source order, last write wins).
      ...extraOverrides,
    ],
    // Use the Deckhand theme so widgets that reach for the
    // [DeckhandTokens] extension (StatusPill, IdTag, TickRule,
    // chrome) find it. Without this, those widgets assert at build
    // time. Light theme picked arbitrarily — both ship the same
    // extension instance.
    child: MaterialApp.router(
      routerConfig: router,
      theme: DeckhandTheme.light(),
      darkTheme: DeckhandTheme.dark(),
    ),
  );
}

/// Variant that also lets tests seed [DeckhandSettings]. Needed for
/// screens that hydrate preferences from settings on first build
/// (e.g. the Verify screen reads `pruneOlderThanDays` to preselect
/// the dropdown).
Widget testHarnessWithSettings({
  required WizardController controller,
  required Widget child,
  required void Function(DeckhandSettings) settingsSeed,
  String initialLocation = '/',
}) {
  final router = GoRouter(
    initialLocation: initialLocation,
    routes: [
      for (final path in const [
        '/',
        '/printers',
        '/pick-printer',
        '/connect',
        '/verify',
        '/choose-path',
        '/firmware',
        '/webui',
        '/kiauh',
        '/screen-choice',
        '/services',
        '/files',
        '/snapshot',
        '/emmc-backup',
        '/hardening',
        '/flash-target',
        '/choose-os',
        '/flash-confirm',
        '/first-boot',
        '/first-boot-setup',
        '/review',
        '/progress',
        '/done',
        '/manage',
        '/emmc-restore',
        '/settings',
      ])
        GoRoute(path: path, builder: (_, _) => child),
    ],
  );
  final settings = DeckhandSettings(path: '<memory>');
  settingsSeed(settings);
  return ProviderScope(
    overrides: [
      ...overrideForController(controller),
      deckhandSettingsProvider.overrideWithValue(settings),
    ],
    // Use the Deckhand theme so widgets that reach for the
    // [DeckhandTokens] extension (StatusPill, IdTag, TickRule,
    // chrome) find it. Without this, those widgets assert at build
    // time. Light theme picked arbitrarily — both ship the same
    // extension instance.
    child: MaterialApp.router(
      routerConfig: router,
      theme: DeckhandTheme.light(),
      darkTheme: DeckhandTheme.dark(),
    ),
  );
}

/// Builds a minimal profile JSON that [PrinterProfile.fromJson] can
/// parse. Tests pass overrides for whatever sub-trees they care about.
Map<String, dynamic> testProfileJson({
  Map<String, dynamic>? stack,
  Map<String, dynamic>? os,
  List<Map<String, dynamic>>? stockKeepSteps,
  List<Map<String, dynamic>>? freshFlashSteps,
}) => {
  'profile_id': 'test-printer',
  'profile_version': '0.1.0',
  'display_name': 'Test Printer',
  'status': 'alpha',
  'manufacturer': 'Acme',
  'model': 'Robo',
  'os':
      os ??
      {
        'fresh_install_options': [
          {
            'id': 'debian-bookworm',
            'display_name': 'Debian 12',
            'url': 'https://example.com/img',
            'recommended': true,
          },
        ],
      },
  'ssh': {
    'default_port': 22,
    'default_credentials': [
      {'user': 'root', 'password': 'root'},
    ],
  },
  'stack': ?stack,
  'flows': {
    'stock_keep': {'enabled': true, 'steps': stockKeepSteps ?? const []},
    if (freshFlashSteps != null)
      'fresh_flash': {'enabled': true, 'steps': freshFlashSteps},
  },
};

/// Stubs a WizardController with minimal fake services - enough for
/// widget tests to mount screens that read from the provider.
WizardController stubWizardController({
  required Map<String, dynamic> profileJson,
  UpstreamService? upstream,
  SecurityService? security,
}) {
  return WizardController(
    profiles: _StubProfileService(PrinterProfile.fromJson(profileJson)),
    ssh: _StubSsh(),
    flash: _StubFlash(),
    discovery: _StubDiscovery(),
    moonraker: _StubMoonraker(),
    upstream: upstream ?? _StubUpstream(),
    security: security ?? _StubSecurity(),
  );
}

/// Standard provider overrides for widget tests so anything that reads
/// from [wizardControllerProvider] or a service provider gets a stub.
List<Override> overrideForController(
  WizardController controller, {
  DoctorService? doctor,
}) => [
  profileServiceProvider.overrideWithValue(
    _StubProfileService(controller.profile!),
  ),
  sshServiceProvider.overrideWithValue(_StubSsh()),
  flashServiceProvider.overrideWithValue(_StubFlash()),
  discoveryServiceProvider.overrideWithValue(_StubDiscovery()),
  moonrakerServiceProvider.overrideWithValue(_StubMoonraker()),
  upstreamServiceProvider.overrideWithValue(controller.upstream),
  securityServiceProvider.overrideWithValue(controller.security),
  doctorServiceProvider.overrideWithValue(doctor ?? _StubDoctor.healthy()),
  wizardControllerProvider.overrideWithValue(controller),
];

/// Stub [DoctorService] used by widget tests. [_StubDoctor.healthy]
/// returns a passing report; tests that exercise failure rendering
/// pass [_StubDoctor.withResults] to override.
class _StubDoctor implements DoctorService {
  _StubDoctor(this._report);

  factory _StubDoctor.healthy() => _StubDoctor(
    const DoctorReport(
      passed: true,
      results: [
        DoctorResult(
          name: 'runtime',
          status: DoctorStatus.pass,
          detail: 'os=test',
        ),
      ],
      report: '[PASS] runtime — os=test\n\nall checks passed\n',
    ),
  );

  final DoctorReport _report;

  @override
  Future<DoctorReport> run() async => _report;
}

// -----------------------------------------------------------------
// Stub services - tests override what they need.

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

class _StubSsh implements SshService {
  @override
  Future<SshSession> connect({
    required String host,
    int port = 22,
    required SshCredential credential,
    bool acceptHostKey = false,
    String? acceptedHostFingerprint,
  }) async => SshSession(id: 'stub', host: host, port: port, user: 'root');
  @override
  Future<SshSession> tryDefaults({
    required String host,
    int port = 22,
    required List<SshCredential> credentials,
    bool acceptHostKey = false,
    String? acceptedHostFingerprint,
  }) async => SshSession(id: 'stub', host: host, port: port, user: 'root');
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
        hostname: 'stub',
        softwareVersion: '',
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
    value: 'stub-token-0123456789abcdef',
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
