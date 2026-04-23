import 'dart:async';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/providers.dart';
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
}) {
  final router = GoRouter(
    initialLocation: initialLocation,
    routes: [
      for (final path in const [
        '/',
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
        '/hardening',
        '/flash-target',
        '/choose-os',
        '/flash-confirm',
        '/first-boot',
        '/first-boot-setup',
        '/review',
        '/progress',
        '/done',
        '/settings',
      ])
        GoRoute(path: path, builder: (_, __) => child),
    ],
  );
  return ProviderScope(
    overrides: overrideForController(controller),
    child: MaterialApp.router(routerConfig: router),
  );
}

/// Builds a minimal profile JSON that [PrinterProfile.fromJson] can
/// parse. Tests pass overrides for whatever sub-trees they care about.
Map<String, dynamic> testProfileJson({
  Map<String, dynamic>? stack,
  Map<String, dynamic>? os,
  List<Map<String, dynamic>>? stockKeepSteps,
}) => {
      'profile_id': 'test-printer',
      'profile_version': '0.1.0',
      'display_name': 'Test Printer',
      'status': 'alpha',
      'manufacturer': 'Acme',
      'model': 'Robo',
      if (os != null) 'os': os,
      'os': os ??
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
      if (stack != null) 'stack': stack,
      'flows': {
        'stock_keep': {
          'enabled': true,
          'steps': stockKeepSteps ?? const [],
        },
      },
    };

/// Stubs a WizardController with minimal fake services - enough for
/// widget tests to mount screens that read from the provider.
WizardController stubWizardController({
  required Map<String, dynamic> profileJson,
}) {
  return WizardController(
    profiles: _StubProfileService(PrinterProfile.fromJson(profileJson)),
    ssh: _StubSsh(),
    flash: _StubFlash(),
    discovery: _StubDiscovery(),
    moonraker: _StubMoonraker(),
    upstream: _StubUpstream(),
    security: _StubSecurity(),
  );
}

/// Standard provider overrides for widget tests so anything that reads
/// from [wizardControllerProvider] or a service provider gets a stub.
List<Override> overrideForController(WizardController controller) => [
      profileServiceProvider.overrideWithValue(
        _StubProfileService(controller.profile!),
      ),
      sshServiceProvider.overrideWithValue(_StubSsh()),
      flashServiceProvider.overrideWithValue(_StubFlash()),
      discoveryServiceProvider.overrideWithValue(_StubDiscovery()),
      moonrakerServiceProvider.overrideWithValue(_StubMoonraker()),
      upstreamServiceProvider.overrideWithValue(_StubUpstream()),
      securityServiceProvider.overrideWithValue(_StubSecurity()),
      wizardControllerProvider.overrideWithValue(controller),
    ];

// -----------------------------------------------------------------
// Stub services - tests override what they need.

class _StubProfileService implements ProfileService {
  _StubProfileService(this.profile);
  final PrinterProfile profile;
  @override
  Future<ProfileCacheEntry> ensureCached({
    required String profileId,
    String? ref,
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
  }) async => SshSession(id: 'stub', host: host, port: port, user: 'root');
  @override
  Future<SshSession> tryDefaults({
    required String host,
    int port = 22,
    required List<SshCredential> credentials,
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
  Future<void> disconnect(SshSession session) async {}
}

class _StubFlash implements FlashService {
  @override
  Future<List<DiskInfo>> listDisks() async => const [];
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
      );
  @override
  Future<bool> isHostAllowed(String host) async => true;
  @override
  Future<void> pinHostFingerprint({
    required String host,
    required String fingerprint,
  }) async {}
  @override
  Future<String?> pinnedHostFingerprint(String host) async => null;
  @override
  Future<Map<String, bool>> requestHostApprovals(List<String> hosts) async => {
        for (final h in hosts) h: true,
      };
}
