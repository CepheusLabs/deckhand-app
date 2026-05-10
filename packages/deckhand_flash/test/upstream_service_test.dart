import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_flash/deckhand_flash.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('SidecarUpstreamService.gitFetch', () {
    test('rejects sidecar profile fetch responses without local_path', () async {
      final sidecar = _FakeSidecar(
        hash:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        profilesFetchResult: const {'resolved_ref': 'abc123'},
      );
      final svc = SidecarUpstreamService(
        sidecar: sidecar,
        security: _AllowAllSecurity(),
      );

      await expectLater(
        svc.gitFetch(
          repoUrl: 'https://example.com/profiles.git',
          ref: 'main',
          destPath: '/tmp/profiles',
        ),
        throwsA(
          isA<UpstreamException>().having(
            (e) => e.message,
            'message',
            contains('local_path'),
          ),
        ),
      );
    });
  });

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
      expect(sidecar.hashPaths, [p.join(tmp.path, 'fluidd.zip.download')]);
      expect(
        File(p.join(tmp.path, 'fluidd.zip.download')).existsSync(),
        isFalse,
      );
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
      expect(
        File(p.join(tmp.path, 'fluidd.zip.download')).existsSync(),
        isFalse,
      );
    });

    test('clears stale release asset temp files before downloading', () async {
      final tmp = await Directory.systemTemp.createTemp('deckhand-upstream-');
      addTearDown(() async => tmp.delete(recursive: true));

      final temp = File(p.join(tmp.path, 'fluidd.zip.download'));
      await temp.writeAsString('interrupted previous download');
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

      expect(await File(res.localPath).readAsString(), 'asset-bytes');
      expect(temp.existsSync(), isFalse);
      expect(sidecar.hashPaths, [temp.path]);
    });

    test('rejects invalid sidecar hash responses', () async {
      final tmp = await Directory.systemTemp.createTemp('deckhand-upstream-');
      addTearDown(() async => tmp.delete(recursive: true));

      final expected =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final sidecar = _FakeSidecar(hash: 'not-a-sha');
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
        throwsA(
          isA<UpstreamException>().having(
            (e) => e.message,
            'message',
            contains('invalid sha256'),
          ),
        ),
      );
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

    test('requires approval for release asset redirect targets', () async {
      final tmp = await Directory.systemTemp.createTemp('deckhand-upstream-');
      addTearDown(() async => tmp.delete(recursive: true));

      final security = _AllowAllSecurity(
        allowedHosts: {'api.github.com', 'downloads.example'},
      );
      final dio = Dio()
        ..httpClientAdapter = _FakeGitHubAdapter(
          redirectAssetTo: 'https://redirected.example/fluidd.zip',
        );
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
            'redirected.example',
          ),
        ),
      );
      expect(security.checkedHosts, [
        'api.github.com',
        'downloads.example',
        'redirected.example',
      ]);
    });

    test(
      'reuses a verified existing release asset without redownloading',
      () async {
        final tmp = await Directory.systemTemp.createTemp('deckhand-upstream-');
        addTearDown(() async => tmp.delete(recursive: true));

        final expected =
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        final existing = File(p.join(tmp.path, 'fluidd.zip'));
        await existing.writeAsString('cached-asset');
        final sidecar = _FakeSidecar(hash: expected);
        final adapter = _FakeGitHubAdapter();
        final dio = Dio()..httpClientAdapter = adapter;
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

        expect(res.localPath, existing.path);
        expect(await existing.readAsString(), 'cached-asset');
        expect(adapter.assetDownloadCount, 0);
        expect(sidecar.hashPaths, [existing.path]);
      },
    );

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

    test('skips malformed release asset rows while matching assets', () async {
      final tmp = await Directory.systemTemp.createTemp('deckhand-upstream-');
      addTearDown(() async => tmp.delete(recursive: true));

      final expected =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final sidecar = _FakeSidecar(hash: expected);
      final dio = Dio()
        ..httpClientAdapter = _FakeGitHubAdapter(
          assets: const [
            'not an object',
            {'name': 42, 'browser_download_url': 'https://bad.example/a.zip'},
            {
              'name': 'fluidd.zip',
              'browser_download_url': 'https://downloads.example/fluidd.zip',
            },
          ],
        );
      final svc = SidecarUpstreamService(
        sidecar: sidecar,
        security: _AllowAllSecurity(),
        dio: dio,
      );

      final res = await svc.releaseFetch(
        repoSlug: 'fluidd-core/fluidd',
        assetPattern: '*.zip',
        destPath: tmp.path,
        expectedSha256: expected,
      );

      expect(res.assetName, 'fluidd.zip');
      expect(await File(res.localPath).readAsString(), 'asset-bytes');
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

    test('rejects unmanaged destinations before host approval', () async {
      final sidecar = _FakeSidecar(
        hash:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      final security = _AllowAllSecurity();
      final svc = SidecarUpstreamService(sidecar: sidecar, security: security);

      await expectLater(
        svc
            .osDownload(
              url: 'https://example.com/image.img',
              destPath: p.join(await _unmanagedTempDir(), 'image.img'),
              expectedSha256:
                  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            )
            .drain<void>(),
        throwsA(
          isA<UpstreamException>().having(
            (e) => e.message,
            'message',
            contains('managed OS image cache'),
          ),
        ),
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
            destPath: _managedOsImageDest('image.img'),
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

    test('accepts an injected managed OS image cache root', () async {
      final root = await Directory.systemTemp.createTemp(
        'deckhand-managed-os-cache-',
      );
      addTearDown(() async => root.delete(recursive: true));
      final dest = p.join(root.path, 'image.img');
      final expected =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final sidecar = _FakeSidecar(
        hash: expected,
        streamEvents: [
          SidecarResult({'sha256': expected, 'path': dest, 'reused': true}),
        ],
      );
      final security = _AllowAllSecurity();
      final svc = SidecarUpstreamService(
        sidecar: sidecar,
        security: security,
        osImagesDir: root.path,
      );

      await svc
          .osDownload(
            url: 'https://example.com/image.img',
            destPath: dest,
            expectedSha256: expected,
          )
          .drain<void>();

      expect(sidecar.streamingCalls, hasLength(1));
      expect(sidecar.streamingCalls.single.params['dest'], dest);
      expect(security.checkedHosts, ['example.com']);
    });

    test('reuses an existing image when its sha256 matches', () async {
      final dest = _managedOsImageDest('reused-image.img');
      addTearDown(() async {
        await _deleteIfExists(dest);
        await _deleteIfExists('$dest.deckhand-download.json');
      });
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

    test('reuses verified local image before host approval', () async {
      final dest = _managedOsImageDest('local-preflight-reuse.img');
      addTearDown(() async {
        await _deleteIfExists(dest);
        await _deleteIfExists('$dest.part');
        await _deleteIfExists('$dest.download.part');
        await _deleteIfExists('$dest.deckhand-download.json');
      });
      await Directory(p.dirname(dest)).create(recursive: true);
      const cachedBody = 'cached-image';
      await File(dest).writeAsString(cachedBody);
      await File('$dest.part').writeAsString('stale extracted partial');
      await File(
        '$dest.download.part',
      ).writeAsString('stale downloaded artifact');
      final expected = sha256.convert(utf8.encode(cachedBody)).toString();
      final sidecar = _FakeSidecar(
        hash:
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      );
      final security = _AllowAllSecurity(allowedHosts: const {});
      final svc = SidecarUpstreamService(sidecar: sidecar, security: security);

      final events = await svc
          .osDownload(
            url: 'https://blocked.example.com/image.img',
            destPath: dest,
            expectedSha256: expected,
          )
          .toList();

      expect(events, hasLength(1));
      expect(events.single.phase, OsDownloadPhase.done);
      expect(events.single.reused, isTrue);
      expect(events.single.path, dest);
      expect(sidecar.hashPaths, isEmpty);
      expect(sidecar.streamingCalls, isEmpty);
      expect(security.checkedHosts, isEmpty);
      expect(File('$dest.part').existsSync(), isFalse);
      expect(File('$dest.download.part').existsSync(), isFalse);
      final manifest = await File(
        '$dest.deckhand-download.json',
      ).readAsString();
      expect(manifest, contains('"reused_at"'));
    });

    test(
      'preserves original download time when reusing local images',
      () async {
        final dest = _managedOsImageDest('local-reuse-preserves-download.img');
        addTearDown(() async {
          await _deleteIfExists(dest);
          await _deleteIfExists('$dest.deckhand-download.json');
        });
        await Directory(p.dirname(dest)).create(recursive: true);
        const cachedBody = 'cached-image';
        await File(dest).writeAsString(cachedBody);
        final expected = sha256.convert(utf8.encode(cachedBody)).toString();
        await File('$dest.deckhand-download.json').writeAsString(
          jsonEncode({
            'schema_version': 1,
            'url': 'https://blocked.example.com/image.img',
            'path': dest,
            'expected_sha256': expected,
            'actual_sha256': expected,
            'downloaded_at': '2026-05-04T12:00:00Z',
          }),
        );
        final sidecar = _FakeSidecar(hash: expected);
        final security = _AllowAllSecurity(allowedHosts: const {});
        final svc = SidecarUpstreamService(
          sidecar: sidecar,
          security: security,
        );

        await svc
            .osDownload(
              url: 'https://blocked.example.com/image.img',
              destPath: dest,
              expectedSha256: expected,
            )
            .drain<void>();

        final manifest =
            jsonDecode(
                  await File('$dest.deckhand-download.json').readAsString(),
                )
                as Map<String, dynamic>;
        expect(manifest['downloaded_at'], '2026-05-04T12:00:00Z');
        expect(manifest['reused_at'], isA<String>());
      },
    );

    test('writes OS image manifests through a clean temp file', () async {
      final dest = _managedOsImageDest('atomic-local-reuse.img');
      final manifestPath = '$dest.deckhand-download.json';
      final tmpManifestPath = '$manifestPath.tmp';
      addTearDown(() async {
        await _deleteIfExists(dest);
        await _deleteIfExists(manifestPath);
        await _deleteIfExists(tmpManifestPath);
      });
      await Directory(p.dirname(dest)).create(recursive: true);
      const cachedBody = 'cached-image';
      await File(dest).writeAsString(cachedBody);
      final expected = sha256.convert(utf8.encode(cachedBody)).toString();
      await File(manifestPath).writeAsString(
        jsonEncode({
          'schema_version': 1,
          'url': 'https://blocked.example.com/image.img',
          'path': dest,
          'expected_sha256': expected,
          'actual_sha256': expected,
          'downloaded_at': '2026-05-04T12:00:00Z',
        }),
      );
      await File(tmpManifestPath).writeAsString('{partial');
      final sidecar = _FakeSidecar(hash: expected);
      final security = _AllowAllSecurity(allowedHosts: const {});
      final svc = SidecarUpstreamService(sidecar: sidecar, security: security);

      await svc
          .osDownload(
            url: 'https://blocked.example.com/image.img',
            destPath: dest,
            expectedSha256: expected,
          )
          .drain<void>();

      expect(File(tmpManifestPath).existsSync(), isFalse);
      final manifest =
          jsonDecode(await File(manifestPath).readAsString())
              as Map<String, dynamic>;
      expect(manifest['downloaded_at'], '2026-05-04T12:00:00Z');
      expect(manifest['reused_at'], isA<String>());
    });

    test(
      'rejects invalid OS image manifest paths without leaving temp files',
      () async {
        final dest = _managedOsImageDest('atomic-local-reuse-fail.img');
        final manifestPath = '$dest.deckhand-download.json';
        final tmpManifestPath = '$manifestPath.tmp';
        addTearDown(() async {
          await _deleteIfExists(dest);
          await _deleteIfExists(tmpManifestPath);
          final manifestType = await FileSystemEntity.type(
            manifestPath,
            followLinks: false,
          );
          if (manifestType == FileSystemEntityType.directory) {
            await Directory(manifestPath).delete(recursive: true);
          } else {
            await _deleteIfExists(manifestPath);
          }
        });
        await Directory(p.dirname(dest)).create(recursive: true);
        const cachedBody = 'cached-image';
        await File(dest).writeAsString(cachedBody);
        await Directory(manifestPath).create();
        final expected = sha256.convert(utf8.encode(cachedBody)).toString();
        final sidecar = _FakeSidecar(hash: expected);
        final security = _AllowAllSecurity(allowedHosts: const {});
        final svc = SidecarUpstreamService(
          sidecar: sidecar,
          security: security,
        );

        await expectLater(
          svc
              .osDownload(
                url: 'https://blocked.example.com/image.img',
                destPath: dest,
                expectedSha256: expected,
              )
              .drain<void>(),
          throwsA(isA<UpstreamException>()),
        );

        expect(File(tmpManifestPath).existsSync(), isFalse);
        expect(Directory(manifestPath).existsSync(), isTrue);
      },
    );

    test('does not reuse stale xz bytes masquerading as an image', () async {
      final dest = _managedOsImageDest('stale-xz-cache.img');
      addTearDown(() async {
        await _deleteIfExists(dest);
        await _deleteIfExists('$dest.deckhand-download.json');
      });
      await Directory(p.dirname(dest)).create(recursive: true);
      final staleXzBytes = <int>[0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00, 1, 2];
      await File(dest).writeAsBytes(staleXzBytes);
      final expectedArtifactSha = sha256.convert(staleXzBytes).toString();
      final finalImageSha =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      final sidecar = _FakeSidecar(
        hash: finalImageSha,
        streamEvents: [
          SidecarResult({
            'sha256': finalImageSha,
            'path': dest,
            'reused': false,
          }),
        ],
      );
      final security = _AllowAllSecurity();
      final svc = SidecarUpstreamService(sidecar: sidecar, security: security);

      final events = await svc
          .osDownload(
            url: 'https://example.com/image.img.xz',
            destPath: dest,
            expectedSha256: expectedArtifactSha,
          )
          .toList();

      expect(events.single.sha256, finalImageSha);
      expect(events.single.reused, isFalse);
      expect(File(dest).existsSync(), isFalse);
      expect(sidecar.streamingCalls, hasLength(1));
      expect(security.checkedHosts, ['example.com']);
    });

    test('clears extracted xz images without a matching manifest', () async {
      final dest = _managedOsImageDest('manifestless-xz-cache.img');
      addTearDown(() async {
        await _deleteIfExists(dest);
        await _deleteIfExists('$dest.deckhand-download.json');
      });
      await Directory(p.dirname(dest)).create(recursive: true);
      await File(dest).writeAsString('raw image without provenance');
      final imageSha =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      final artifactSha =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final sidecar = _FakeSidecar(
        hash: imageSha,
        streamEvents: [
          SidecarResult({'sha256': imageSha, 'path': dest, 'reused': false}),
        ],
      );
      final security = _AllowAllSecurity();
      final svc = SidecarUpstreamService(sidecar: sidecar, security: security);

      final events = await svc
          .osDownload(
            url: 'https://example.com/image.img.xz',
            destPath: dest,
            expectedSha256: artifactSha,
          )
          .toList();

      expect(events.single.sha256, imageSha);
      expect(File(dest).existsSync(), isFalse);
      expect(sidecar.streamingCalls, hasLength(1));
      expect(security.checkedHosts, ['example.com']);
    });

    test(
      'clears stale extracted image partials before sidecar download',
      () async {
        final dest = _managedOsImageDest('stale-part-cache.img');
        addTearDown(() async {
          await _deleteIfExists(dest);
          await _deleteIfExists('$dest.part');
          await _deleteIfExists('$dest.deckhand-download.json');
        });
        await Directory(p.dirname(dest)).create(recursive: true);
        await File('$dest.part').writeAsString('interrupted extraction');
        final imageSha =
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
        final artifactSha =
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        final sidecar = _FakeSidecar(
          hash: imageSha,
          streamEvents: [
            SidecarResult({'sha256': imageSha, 'path': dest, 'reused': false}),
          ],
        );
        final security = _AllowAllSecurity();
        final svc = SidecarUpstreamService(
          sidecar: sidecar,
          security: security,
        );

        await svc
            .osDownload(
              url: 'https://example.com/image.img.xz',
              destPath: dest,
              expectedSha256: artifactSha,
            )
            .drain<void>();

        expect(File('$dest.part').existsSync(), isFalse);
        expect(sidecar.streamingCalls, hasLength(1));
        expect(security.checkedHosts, ['example.com']);
      },
    );

    test('reuses extracted xz images only when the manifest matches', () async {
      final dest = _managedOsImageDest('extracted-xz-cache.img');
      addTearDown(() async {
        await _deleteIfExists(dest);
        await _deleteIfExists('$dest.deckhand-download.json');
      });
      await Directory(p.dirname(dest)).create(recursive: true);
      const body = 'raw image bytes';
      await File(dest).writeAsString(body);
      final imageSha = sha256.convert(utf8.encode(body)).toString();
      final artifactSha =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      await File('$dest.deckhand-download.json').writeAsString(
        jsonEncode({
          'schema_version': 1,
          'url': 'https://example.com/image.img.xz',
          'path': dest,
          'expected_sha256': artifactSha,
          'actual_sha256': imageSha,
        }),
      );
      final sidecar = _FakeSidecar(hash: imageSha);
      final security = _AllowAllSecurity(allowedHosts: const {});
      final svc = SidecarUpstreamService(sidecar: sidecar, security: security);

      final events = await svc
          .osDownload(
            url: 'https://example.com/image.img.xz',
            destPath: dest,
            expectedSha256: artifactSha,
          )
          .toList();

      expect(events.single.sha256, imageSha);
      expect(events.single.reused, isTrue);
      expect(sidecar.streamingCalls, isEmpty);
      expect(security.checkedHosts, isEmpty);
    });

    test('clears malformed xz image manifests instead of crashing', () async {
      final dest = _managedOsImageDest('malformed-xz-manifest.img');
      addTearDown(() async {
        await _deleteIfExists(dest);
        await _deleteIfExists('$dest.deckhand-download.json');
      });
      await Directory(p.dirname(dest)).create(recursive: true);
      await File(dest).writeAsString('raw image bytes');
      await File('$dest.deckhand-download.json').writeAsString(
        jsonEncode({
          'schema_version': 1,
          'url': 'https://example.com/image.img.xz',
          'path': dest,
          'expected_sha256':
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          'actual_sha256': 42,
        }),
      );
      final imageSha =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      final sidecar = _FakeSidecar(
        hash: imageSha,
        streamEvents: [
          SidecarResult({'sha256': imageSha, 'path': dest, 'reused': false}),
        ],
      );
      final security = _AllowAllSecurity();
      final svc = SidecarUpstreamService(sidecar: sidecar, security: security);

      final events = await svc
          .osDownload(
            url: 'https://example.com/image.img.xz',
            destPath: dest,
            expectedSha256:
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          )
          .toList();

      expect(events.single.sha256, imageSha);
      expect(events.single.reused, isFalse);
      expect(sidecar.streamingCalls, hasLength(1));
      expect(security.checkedHosts, ['example.com']);
    });

    test('clears corrupt xz image manifests instead of crashing', () async {
      final dest = _managedOsImageDest('corrupt-xz-manifest.img');
      addTearDown(() async {
        await _deleteIfExists(dest);
        await _deleteIfExists('$dest.deckhand-download.json');
      });
      await Directory(p.dirname(dest)).create(recursive: true);
      await File(dest).writeAsString('raw image bytes');
      await File('$dest.deckhand-download.json').writeAsString('{not-json');
      final imageSha =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      final sidecar = _FakeSidecar(
        hash: imageSha,
        streamEvents: [
          SidecarResult({'sha256': imageSha, 'path': dest, 'reused': false}),
        ],
      );
      final security = _AllowAllSecurity();
      final svc = SidecarUpstreamService(sidecar: sidecar, security: security);

      final events = await svc
          .osDownload(
            url: 'https://example.com/image.img.xz',
            destPath: dest,
            expectedSha256:
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          )
          .toList();

      expect(events.single.sha256, imageSha);
      expect(events.single.reused, isFalse);
      expect(sidecar.streamingCalls, hasLength(1));
      expect(security.checkedHosts, ['example.com']);
    });

    test('clears rejected cached image manifests before redownload', () async {
      final dest = _managedOsImageDest('rejected-cache-family.img');
      final manifestPath = '$dest.deckhand-download.json';
      addTearDown(() async {
        await _deleteIfExists(dest);
        await _deleteIfExists(manifestPath);
      });
      await Directory(p.dirname(dest)).create(recursive: true);
      await File(dest).writeAsString('raw image bytes');
      await File(manifestPath).writeAsString(
        jsonEncode({
          'schema_version': 1,
          'url': 'https://example.com/image.img.xz',
          'path': dest,
          'expected_sha256':
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          'actual_sha256':
              'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        }),
      );
      final sidecar = _FakeSidecar(
        hash:
            'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
      );
      final security = _AllowAllSecurity();
      final svc = SidecarUpstreamService(sidecar: sidecar, security: security);

      await svc
          .osDownload(
            url: 'https://example.com/image.img.xz',
            destPath: dest,
            expectedSha256:
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          )
          .drain<void>();

      expect(File(dest).existsSync(), isFalse);
      expect(File(manifestPath).existsSync(), isFalse);
      expect(sidecar.streamingCalls, hasLength(1));
    });

    test('records completed downloads in the image manifest', () async {
      final dest = _managedOsImageDest('downloaded-image.img');
      addTearDown(() async {
        await _deleteIfExists(dest);
        await _deleteIfExists('$dest.deckhand-download.json');
      });
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

    test('records sidecar OS downloads as egress events', () async {
      final dest = _managedOsImageDest('egress-image.img');
      addTearDown(() async {
        await _deleteIfExists(dest);
        await _deleteIfExists('$dest.deckhand-download.json');
      });
      final expected =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final sidecar = _FakeSidecar(
        hash: expected,
        streamEvents: [
          const SidecarProgress(
            SidecarNotification(
              method: 'os.download.progress',
              params: {
                'bytes_done': 1024,
                'bytes_total': 2048,
                'phase': 'downloading',
              },
            ),
          ),
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
          .drain<void>();

      expect(security.egressRecords, hasLength(2));
      expect(security.egressRecords.first.host, 'example.com');
      expect(security.egressRecords.first.operationLabel, 'OS image download');
      expect(security.egressRecords.first.completedAt, isNull);
      expect(
        security.egressRecords.last.requestId,
        security.egressRecords.first.requestId,
      );
      expect(security.egressRecords.last.completedAt, isNotNull);
      expect(security.egressRecords.last.bytes, 1024);
    });

    test('tolerates malformed sidecar progress fields', () async {
      final dest = _managedOsImageDest('malformed-progress.img');
      addTearDown(() async {
        await _deleteIfExists(dest);
        await _deleteIfExists('$dest.deckhand-download.json');
      });
      final expected =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final sidecar = _FakeSidecar(
        hash: expected,
        streamEvents: [
          const SidecarProgress(
            SidecarNotification(
              method: 'os.download.progress',
              params: {
                'bytes_done': 'bad',
                'bytes_total': ['bad'],
                'phase': 42,
              },
            ),
          ),
          SidecarResult({'sha256': expected, 'path': dest, 'reused': false}),
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

      expect(events.first.bytesDone, 0);
      expect(events.first.bytesTotal, 0);
      expect(events.first.phase, OsDownloadPhase.downloading);
      expect(events.last.phase, OsDownloadPhase.done);
    });

    test('rejects sidecar completion without a valid image sha256', () async {
      final dest = _managedOsImageDest('invalid-result-sha.img');
      addTearDown(() async {
        await _deleteIfExists(dest);
        await _deleteIfExists('$dest.deckhand-download.json');
      });
      final expected =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final sidecar = _FakeSidecar(
        hash: expected,
        streamEvents: [
          SidecarResult({'sha256': 'not-a-sha', 'path': dest}),
        ],
      );
      final security = _AllowAllSecurity();
      final svc = SidecarUpstreamService(sidecar: sidecar, security: security);

      await expectLater(
        svc
            .osDownload(
              url: 'https://example.com/image.img',
              destPath: dest,
              expectedSha256: expected,
            )
            .drain<void>(),
        throwsA(
          isA<UpstreamException>().having(
            (e) => e.message,
            'message',
            contains('invalid sha256'),
          ),
        ),
      );
      expect(File('$dest.deckhand-download.json').existsSync(), isFalse);
    });

    test(
      'does not record egress when only extracting a cached artifact',
      () async {
        final dest = _managedOsImageDest('extracting-cached-artifact.img');
        addTearDown(() async {
          await _deleteIfExists(dest);
          await _deleteIfExists('$dest.deckhand-download.json');
        });
        final imageSha =
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
        final artifactSha =
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        final sidecar = _FakeSidecar(
          hash: imageSha,
          streamEvents: [
            const SidecarProgress(
              SidecarNotification(
                method: 'os.download.progress',
                params: {
                  'bytes_done': 1024,
                  'bytes_total': 0,
                  'phase': 'extracting',
                },
              ),
            ),
            SidecarResult({'sha256': imageSha, 'path': dest, 'reused': false}),
          ],
        );
        final security = _AllowAllSecurity();
        final svc = SidecarUpstreamService(
          sidecar: sidecar,
          security: security,
        );

        final events = await svc
            .osDownload(
              url: 'https://example.com/image.img.xz',
              destPath: dest,
              expectedSha256: artifactSha,
            )
            .toList();

        expect(events.first.phase, OsDownloadPhase.extracting);
        expect(events.last.phase, OsDownloadPhase.done);
        expect(security.checkedHosts, ['example.com']);
        expect(security.egressRecords, isEmpty);
      },
    );

    test('rejects sidecar result paths outside the managed cache', () async {
      final dest = _managedOsImageDest('sidecar-path-mismatch.img');
      addTearDown(() async {
        await _deleteIfExists(dest);
        await _deleteIfExists('$dest.deckhand-download.json');
      });
      final unmanaged = p.join(await _unmanagedTempDir(), 'evil.img');
      final expected =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final sidecar = _FakeSidecar(
        hash: expected,
        streamEvents: [
          SidecarResult({'sha256': expected, 'path': unmanaged}),
        ],
      );
      final security = _AllowAllSecurity();
      final svc = SidecarUpstreamService(sidecar: sidecar, security: security);

      await expectLater(
        svc
            .osDownload(
              url: 'https://example.com/image.img',
              destPath: dest,
              expectedSha256: expected,
            )
            .drain<void>(),
        throwsA(
          isA<UpstreamException>().having(
            (e) => e.message,
            'message',
            contains('returned unexpected path'),
          ),
        ),
      );

      expect(File('$unmanaged.deckhand-download.json').existsSync(), isFalse);
    });
  });
}

String _managedOsImageDest(String name) {
  return p.join(Directory.systemTemp.path, 'deckhand-os-images', name);
}

Future<String> _unmanagedTempDir() async {
  final dir = await Directory.systemTemp.createTemp('deckhand-unmanaged-');
  addTearDown(() async => dir.delete(recursive: true));
  return dir.path;
}

Future<void> _deleteIfExists(String path) async {
  final file = File(path);
  if (await file.exists()) {
    await file.delete();
  }
}

class _FakeGitHubAdapter implements HttpClientAdapter {
  _FakeGitHubAdapter({
    this.assetName = 'fluidd.zip',
    this.redirectAssetTo,
    this.assets,
  });

  final String assetName;
  final String? redirectAssetTo;
  final List<Object?>? assets;
  var assetDownloadCount = 0;

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
          'assets':
              assets ??
              [
                {
                  'name': assetName,
                  'browser_download_url':
                      'https://downloads.example/fluidd.zip',
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
      final redirect = redirectAssetTo;
      if (redirect != null) {
        return ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': [redirect],
          },
        );
      }
      assetDownloadCount++;
      return ResponseBody.fromString('asset-bytes', 200);
    }
    if (url == 'https://redirected.example/fluidd.zip') {
      assetDownloadCount++;
      return ResponseBody.fromString('redirected-asset-bytes', 200);
    }
    return ResponseBody.fromString('not found', 404);
  }

  @override
  void close({bool force = false}) {}
}

class _FakeSidecar implements SidecarConnection {
  _FakeSidecar({
    required this.hash,
    List<SidecarEvent>? streamEvents,
    this.profilesFetchResult,
  }) : _streamEvents = streamEvents ?? const [];

  final String hash;
  final List<SidecarEvent> _streamEvents;
  final Map<String, dynamic>? profilesFetchResult;
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
    if (method == 'profiles.fetch') {
      return profilesFetchResult ??
          {'local_path': params['dest'], 'resolved_ref': 'abc123'};
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
  final egressRecords = <EgressEvent>[];

  @override
  Future<ConfirmationToken> issueConfirmationToken({
    required String operation,
    required String target,
    Duration ttl = const Duration(seconds: 60),
  }) async => ConfirmationToken(
    value: 'token-0123456789abcdef',
    expiresAt: DateTime.now().add(ttl),
    operation: operation,
    target: target,
  );

  @override
  bool consumeToken(String value, String operation, {required String target}) =>
      true;

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
  void recordEgress(EgressEvent event) {
    egressRecords.add(event);
  }
}
