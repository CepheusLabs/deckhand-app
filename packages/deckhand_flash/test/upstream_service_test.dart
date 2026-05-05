import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_flash/deckhand_flash.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('SidecarUpstreamService.releaseFetch', () {
    test('verifies downloaded release asset sha256 before returning', () async {
      final tmp = await Directory.systemTemp.createTemp('deckhand-upstream-');
      addTearDown(() async => tmp.delete(recursive: true));

      final expected =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final sidecar = _FakeSidecar(hash: expected);
      final dio = Dio()..httpClientAdapter = _FakeGitHubAdapter();
      final svc = SidecarUpstreamService(
        sidecar: sidecar,
        security: _AllowAllSecurity(),
        dio: dio,
      );

      final res = await svc.releaseFetch(
        repoSlug: 'fluidd-core/fluidd',
        assetPattern: 'fluidd.zip',
        destPath: tmp.path,
        expectedSha256: expected,
      );

      expect(res.assetName, 'fluidd.zip');
      expect(await File(res.localPath).readAsString(), 'asset-bytes');
      expect(sidecar.hashPaths, [p.join(tmp.path, 'fluidd.zip')]);
    });

    test('deletes and rejects release assets with mismatched sha256', () async {
      final tmp = await Directory.systemTemp.createTemp('deckhand-upstream-');
      addTearDown(() async => tmp.delete(recursive: true));

      final expected =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final sidecar = _FakeSidecar(
        hash:
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      );
      final dio = Dio()..httpClientAdapter = _FakeGitHubAdapter();
      final svc = SidecarUpstreamService(
        sidecar: sidecar,
        security: _AllowAllSecurity(),
        dio: dio,
      );

      await expectLater(
        svc.releaseFetch(
          repoSlug: 'fluidd-core/fluidd',
          assetPattern: 'fluidd.zip',
          destPath: tmp.path,
          expectedSha256: expected,
        ),
        throwsA(isA<UpstreamException>()),
      );
      expect(File(p.join(tmp.path, 'fluidd.zip')).existsSync(), isFalse);
    });

    test('requires approval for the actual release asset host', () async {
      final tmp = await Directory.systemTemp.createTemp('deckhand-upstream-');
      addTearDown(() async => tmp.delete(recursive: true));

      final security = _AllowAllSecurity(allowedHosts: {'api.github.com'});
      final dio = Dio()..httpClientAdapter = _FakeGitHubAdapter();
      final svc = SidecarUpstreamService(
        sidecar: _FakeSidecar(
          hash:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ),
        security: security,
        dio: dio,
      );

      await expectLater(
        svc.releaseFetch(
          repoSlug: 'fluidd-core/fluidd',
          assetPattern: 'fluidd.zip',
          destPath: tmp.path,
          expectedSha256:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ),
        throwsA(
          isA<HostNotApprovedException>().having(
            (e) => e.host,
            'host',
            'downloads.example',
          ),
        ),
      );
      expect(security.checkedHosts, ['api.github.com', 'downloads.example']);
    });

    test('rejects release asset names that escape the destination', () async {
      final tmp = await Directory.systemTemp.createTemp('deckhand-upstream-');
      addTearDown(() async => tmp.delete(recursive: true));

      final sidecar = _FakeSidecar(
        hash:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      final dio = Dio()
        ..httpClientAdapter = _FakeGitHubAdapter(assetName: '../escape.zip');
      final svc = SidecarUpstreamService(
        sidecar: sidecar,
        security: _AllowAllSecurity(),
        dio: dio,
      );

      await expectLater(
        svc.releaseFetch(
          repoSlug: 'fluidd-core/fluidd',
          assetPattern: '*.zip',
          destPath: tmp.path,
          expectedSha256:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ),
        throwsA(
          isA<UpstreamException>().having(
            (e) => e.message,
            'message',
            contains('unsafe release asset name'),
          ),
        ),
      );
      expect(sidecar.hashPaths, isEmpty);
      expect(File(p.join(tmp.path, '..', 'escape.zip')).existsSync(), isFalse);
    });
  });

  group('SidecarUpstreamService.osDownload', () {
    test('requires https and sha256 before calling the sidecar', () async {
      final sidecar = _FakeSidecar(
        hash:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      final security = _AllowAllSecurity();
      final svc = SidecarUpstreamService(sidecar: sidecar, security: security);

      await expectLater(
        svc
            .osDownload(
              url: 'http://example.com/image.img',
              destPath: '/tmp/deckhand-os-images/image.img',
              expectedSha256:
                  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            )
            .drain<void>(),
        throwsA(isA<UpstreamException>()),
      );
      await expectLater(
        svc
            .osDownload(
              url: 'https://example.com/image.img',
              destPath: '/tmp/deckhand-os-images/image.img',
            )
            .drain<void>(),
        throwsA(isA<UpstreamException>()),
      );
      expect(sidecar.streamingCalls, isEmpty);
      expect(security.checkedHosts, isEmpty);
    });

    test('passes normalized sha256 to os.download', () async {
      final sidecar = _FakeSidecar(
        hash:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      final security = _AllowAllSecurity();
      final svc = SidecarUpstreamService(sidecar: sidecar, security: security);

      await svc
          .osDownload(
            url: 'https://example.com/image.img',
            destPath: '/tmp/deckhand-os-images/image.img',
            expectedSha256:
                'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
          )
          .drain<void>();

      expect(sidecar.streamingCalls, hasLength(1));
      expect(sidecar.streamingCalls.single.method, 'os.download');
      expect(
        sidecar.streamingCalls.single.params['sha256'],
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
    });

    test('reuses an existing image when its sha256 matches', () async {
      final tmp = await Directory.systemTemp.createTemp('deckhand-upstream-');
      addTearDown(() async => tmp.delete(recursive: true));
      final dest = p.join(tmp.path, 'image.img');
      final expected =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final sidecar = _FakeSidecar(
        hash: expected,
        streamEvents: [
          SidecarResult({'sha256': expected, 'path': dest, 'reused': true}),
        ],
      );
      final security = _AllowAllSecurity();
      final svc = SidecarUpstreamService(sidecar: sidecar, security: security);

      final events = await svc
          .osDownload(
            url: 'https://example.com/image.img',
            destPath: dest,
            expectedSha256: expected,
          )
          .toList();

      expect(events, hasLength(1));
      expect(events.single.phase, OsDownloadPhase.done);
      expect(events.single.reused, isTrue);
      expect(events.single.path, dest);
      expect(sidecar.hashPaths, isEmpty);
      expect(sidecar.streamingCalls, hasLength(1));
      expect(security.checkedHosts, ['example.com']);
      final manifest = await File(
        '$dest.deckhand-download.json',
      ).readAsString();
      expect(manifest, contains('"reused_at"'));
      expect(manifest, contains(expected));
    });

    test('records completed downloads in the image manifest', () async {
      final tmp = await Directory.systemTemp.createTemp('deckhand-upstream-');
      addTearDown(() async => tmp.delete(recursive: true));
      final dest = p.join(tmp.path, 'image.img');
      final expected =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final sidecar = _FakeSidecar(
        hash: expected,
        streamEvents: [
          SidecarResult({'sha256': expected, 'path': dest, 'reused': false}),
        ],
      );
      final security = _AllowAllSecurity();
      final svc = SidecarUpstreamService(sidecar: sidecar, security: security);

      await svc
          .osDownload(
            url: 'https://example.com/image.img',
            destPath: dest,
            expectedSha256: expected,
          )
          .toList();

      expect(sidecar.streamingCalls, hasLength(1));
      expect(security.checkedHosts, ['example.com']);
      final manifest = await File(
        '$dest.deckhand-download.json',
      ).readAsString();
      expect(manifest, contains('"downloaded_at"'));
      expect(manifest, contains(expected));
    });
  });
}

class _FakeGitHubAdapter implements HttpClientAdapter {
  _FakeGitHubAdapter({this.assetName = 'fluidd.zip'});

  final String assetName;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    if (url.endsWith('/repos/fluidd-core/fluidd/releases/latest')) {
      return ResponseBody.fromString(
        jsonEncode({
          'tag_name': 'v1.0.0',
          'assets': [
            {
              'name': assetName,
              'browser_download_url': 'https://downloads.example/fluidd.zip',
            },
          ],
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    if (url == 'https://downloads.example/fluidd.zip') {
      return ResponseBody.fromString('asset-bytes', 200);
    }
    return ResponseBody.fromString('not found', 404);
  }

  @override
  void close({bool force = false}) {}
}

class _FakeSidecar implements SidecarConnection {
  _FakeSidecar({required this.hash, List<SidecarEvent>? streamEvents})
    : _streamEvents = streamEvents ?? const [];

  final String hash;
  final List<SidecarEvent> _streamEvents;
  final hashPaths = <String>[];
  final streamingCalls = <({String method, Map<String, dynamic> params})>[];

  @override
  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params,
  ) async {
    if (method == 'disks.hash') {
      hashPaths.add(params['path'] as String);
      return {'sha256': hash};
    }
    throw StateError('unexpected sidecar method: $method');
  }

  @override
  Stream<SidecarEvent> callStreaming(
    String method,
    Map<String, dynamic> params,
  ) async* {
    streamingCalls.add((method: method, params: params));
    for (final event in _streamEvents) {
      yield event;
    }
  }

  @override
  Stream<SidecarNotification> get notifications => const Stream.empty();

  @override
  Stream<SidecarNotification> subscribeToOperation(String operationId) =>
      const Stream.empty();

  @override
  Future<void> shutdown() async {}
}

class _AllowAllSecurity implements SecurityService {
  _AllowAllSecurity({Set<String>? allowedHosts}) : _allowedHosts = allowedHosts;

  final Set<String>? _allowedHosts;
  final checkedHosts = <String>[];

  @override
  Future<ConfirmationToken> issueConfirmationToken({
    required String operation,
    required String target,
    Duration ttl = const Duration(seconds: 60),
  }) async => ConfirmationToken(
    value: 'token-0123456789abcdef',
    expiresAt: DateTime.now().add(ttl),
    operation: operation,
  );

  @override
  bool consumeToken(String value, String operation) => true;

  @override
  Future<Map<String, bool>> requestHostApprovals(List<String> hosts) async => {
    for (final host in hosts) host: true,
  };

  @override
  Future<bool> isHostAllowed(String host) async {
    checkedHosts.add(host);
    return _allowedHosts?.contains(host) ?? true;
  }

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
