import 'dart:convert';
import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('scanOsImageCache reads image metadata and manifests', () async {
    final root = await Directory.systemTemp.createTemp('deckhand-cache-test-');
    addTearDown(() => root.delete(recursive: true));

    final image = File(p.join(root.path, 'arco.img'));
    await image.writeAsBytes(List<int>.filled(1024, 1));
    final manifest = File('${image.path}$osImageDownloadManifestSuffix');
    await manifest.writeAsString(
      jsonEncode({
        'schema_version': 1,
        'url': 'https://example.com/arco.img.xz',
        'path': image.path,
        'expected_sha256': 'a' * 64,
        'actual_sha256': 'a' * 64,
        'downloaded_at': '2026-05-04T12:00:00Z',
      }),
    );
    await File('${image.path}.part').writeAsBytes([1, 2, 3]);

    final entries = await scanOsImageCache(root.path);

    expect(entries, hasLength(1));
    expect(entries.single.fileName, 'arco.img');
    expect(entries.single.bytes, 1024);
    expect(entries.single.url, 'https://example.com/arco.img.xz');
    expect(entries.single.hasManifest, isTrue);
    expect(entries.single.hashMatchesManifest, isTrue);
  });

  test(
    'deleteOsImageCacheEntry removes image, manifest, and partial',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'deckhand-cache-test-',
      );
      addTearDown(() => root.delete(recursive: true));

      final image = File(p.join(root.path, 'arco.img'));
      final manifest = File('${image.path}$osImageDownloadManifestSuffix');
      final part = File('${image.path}.part');
      await image.writeAsBytes([1]);
      await manifest.writeAsString('{}');
      await part.writeAsBytes([2]);

      await deleteOsImageCacheEntry(root: root.path, imagePath: image.path);

      expect(await image.exists(), isFalse);
      expect(await manifest.exists(), isFalse);
      expect(await part.exists(), isFalse);
    },
  );

  test(
    'deleteOsImageCacheEntry rejects paths outside the cache root',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'deckhand-cache-test-',
      );
      final other = await Directory.systemTemp.createTemp(
        'deckhand-cache-test-',
      );
      addTearDown(() async {
        await root.delete(recursive: true);
        await other.delete(recursive: true);
      });
      final outside = File(p.join(other.path, 'outside.img'));
      await outside.writeAsBytes([1]);

      expect(
        deleteOsImageCacheEntry(root: root.path, imagePath: outside.path),
        throwsA(isA<FileSystemException>()),
      );
    },
  );
}
