import 'dart:convert';
import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  const disk = DiskInfo(
    id: 'disk-1',
    path: r'\\.\PhysicalDrive3',
    sizeBytes: 4096,
    bus: 'USB',
    model: 'Generic STORAGE DEVICE',
    removable: true,
    partitions: [],
  );

  test('serializes and matches a completed backup manifest', () {
    final manifest = EmmcBackupManifest.create(
      profileId: 'phrozen-arco',
      imagePath: r'C:\Deckhand\phrozen-arco.img',
      imageBytes: 4096,
      imageSha256: 'a' * 64,
      disk: disk,
      deckhandVersion: 'dev',
    );

    final parsed = EmmcBackupManifest.fromJson(manifest.toJson());

    expect(parsed.profileId, 'phrozen-arco');
    expect(parsed.disk.model, 'Generic STORAGE DEVICE');
    expect(parsed.matches(profileId: 'phrozen-arco', disk: disk), isTrue);
    expect(parsed.matches(profileId: 'other', disk: disk), isFalse);
    expect(
      parsed.matches(
        profileId: 'phrozen-arco',
        disk: const DiskInfo(
          id: 'disk-2',
          path: r'\\.\PhysicalDrive4',
          sizeBytes: 8192,
          bus: 'USB',
          model: 'Generic STORAGE DEVICE',
          removable: true,
          partitions: [],
        ),
      ),
      isFalse,
    );
  });

  test('does not match a generic same-size USB disk by model and bus only', () {
    final manifest = EmmcBackupManifest.create(
      profileId: 'phrozen-arco',
      imagePath: r'C:\Deckhand\phrozen-arco.img',
      imageBytes: 4096,
      imageSha256: 'a' * 64,
      disk: disk,
      deckhandVersion: 'dev',
    );

    const otherGenericUsb = DiskInfo(
      id: 'disk-2',
      path: r'\\.\PhysicalDrive4',
      sizeBytes: 4096,
      bus: 'USB',
      model: 'Generic STORAGE DEVICE',
      removable: true,
      partitions: [],
    );

    expect(
      manifest.matches(profileId: 'phrozen-arco', disk: otherGenericUsb),
      isFalse,
    );
  });

  test('scanner returns only manifests with existing images', () async {
    final dir = await Directory.systemTemp.createTemp(
      'deckhand_emmc_manifest_',
    );
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    final image = File('${dir.path}/backup.img');
    await image.writeAsBytes(List<int>.filled(4096, 7), flush: true);
    final valid = EmmcBackupManifest.create(
      profileId: 'phrozen-arco',
      imagePath: image.path,
      imageBytes: 4096,
      imageSha256: 'b' * 64,
      disk: disk,
      deckhandVersion: 'dev',
    );
    await writeEmmcBackupManifest(valid);

    await File('${dir.path}/bad.img.manifest.json').writeAsString('{nope');
    await writeEmmcBackupManifest(
      EmmcBackupManifest.create(
        profileId: 'phrozen-arco',
        imagePath: '${dir.path}/missing.img',
        imageBytes: 4096,
        imageSha256: 'c' * 64,
        disk: disk,
        deckhandVersion: 'dev',
      ),
    );

    final manifests = await scanEmmcBackupManifests(dir.path);

    expect(manifests, hasLength(1));
    expect(manifests.single.imagePath, image.path);
  });

  test(
    'scanner returns full-size image candidates without manifests',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'deckhand_emmc_candidate_',
      );
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });

      final image = File(p.join(dir.path, 'phrozen-arco-emmc-2026.img'));
      await image.writeAsBytes(List<int>.filled(4096, 7), flush: true);
      await File('${dir.path}/notes.txt').writeAsString('ignore');

      final candidates = await scanEmmcBackupImageCandidates(dir.path);
      final match = findMatchingEmmcBackupImageCandidate(
        candidates: candidates,
        profileId: 'phrozen-arco',
        disk: disk,
      );

      expect(candidates, hasLength(1));
      expect(candidates.single.imagePath, image.path);
      expect(candidates.single.imageBytes, 4096);
      expect(candidates.single.inferredProfileId, 'phrozen-arco');
      expect(match?.imagePath, image.path);
    },
  );

  test('backup image paths are organized by profile and timestamp', () {
    final path = emmcBackupImagePath(
      rootDir: r'C:\Deckhand\emmc-backups',
      profileId: 'Phrozen Arco!',
      createdAt: DateTime.utc(2026, 5, 7, 18, 19, 20),
    );

    expect(
      path,
      p.join(
        r'C:\Deckhand\emmc-backups',
        'phrozen-arco',
        '2026-05-07T18-19-20Z',
        'emmc.img',
      ),
    );
  });

  test('scanners include organized backup subfolders', () async {
    final dir = await Directory.systemTemp.createTemp('deckhand_emmc_nested_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    final image = File(
      emmcBackupImagePath(
        rootDir: dir.path,
        profileId: 'phrozen-arco',
        createdAt: DateTime.utc(2026, 5, 7, 18, 19, 20),
      ),
    );
    await image.parent.create(recursive: true);
    await image.writeAsBytes(List<int>.filled(4096, 7), flush: true);
    final manifest = EmmcBackupManifest.create(
      profileId: 'phrozen-arco',
      imagePath: image.path,
      imageBytes: 4096,
      imageSha256: 'd' * 64,
      disk: disk,
      deckhandVersion: 'dev',
    );
    await writeEmmcBackupManifest(manifest);

    final loose = File(
      p.join(dir.path, 'sovol-zero', '2026-05-07T19-00-00Z', 'emmc.img'),
    );
    await loose.parent.create(recursive: true);
    await loose.writeAsBytes(List<int>.filled(2048, 3), flush: true);

    final manifests = await scanEmmcBackupManifests(dir.path);
    final candidates = await scanEmmcBackupImageCandidates(dir.path);

    expect(manifests.map((m) => m.imagePath), contains(image.path));
    expect(candidates.map((c) => c.imagePath), contains(image.path));
    expect(candidates.map((c) => c.imagePath), contains(loose.path));
    expect(
      candidates.firstWhere((c) => c.imagePath == loose.path).inferredProfileId,
      'sovol-zero',
    );
  });

  test('organizer moves loose backups beside corrected manifests', () async {
    final dir = await Directory.systemTemp.createTemp(
      'deckhand_emmc_organize_',
    );
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    final image = File(p.join(dir.path, 'phrozen-arco-emmc-legacy.img'));
    await image.writeAsBytes(List<int>.filled(4096, 7), flush: true);
    final manifest = EmmcBackupManifest.create(
      profileId: 'phrozen-arco',
      imagePath: image.path,
      imageBytes: 4096,
      imageSha256: 'e' * 64,
      disk: disk,
      deckhandVersion: 'dev',
      createdAt: DateTime.utc(2026, 5, 7, 18, 19, 20),
    );
    await writeEmmcBackupManifest(manifest);

    final result = await organizeLegacyEmmcBackups(dir.path);
    final movedPath = p.join(
      dir.path,
      'phrozen-arco',
      '2026-05-07T18-19-20Z',
      'emmc.img',
    );

    expect(result.moved, 1);
    expect(await image.exists(), isFalse);
    expect(await File(emmcBackupManifestPath(image.path)).exists(), isFalse);
    expect(await File(movedPath).exists(), isTrue);

    final movedManifestFile = File(emmcBackupManifestPath(movedPath));
    expect(await movedManifestFile.exists(), isTrue);
    final movedManifest = EmmcBackupManifest.fromJson(
      jsonDecode(await movedManifestFile.readAsString())
          as Map<String, dynamic>,
    );
    expect(movedManifest.imagePath, movedPath);
    expect(movedManifest.profileId, 'phrozen-arco');
  });

  test('organizer keeps same-second backups as separate folders', () async {
    final dir = await Directory.systemTemp.createTemp(
      'deckhand_emmc_organize_collision_',
    );
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    final modified = DateTime.utc(2026, 5, 7, 18, 19, 20);
    final first = File(p.join(dir.path, 'phrozen-arco-emmc-a.img'));
    final second = File(p.join(dir.path, 'phrozen-arco-emmc-b.img'));
    await first.writeAsBytes(List<int>.filled(1024, 1), flush: true);
    await second.writeAsBytes(List<int>.filled(2048, 2), flush: true);
    await first.setLastModified(modified);
    await second.setLastModified(modified);

    final result = await organizeLegacyEmmcBackups(dir.path);

    expect(result.moved, 2);
    expect(
      await File(
        p.join(dir.path, 'phrozen-arco', '2026-05-07T18-19-20Z', 'emmc.img'),
      ).exists(),
      isTrue,
    );
    expect(
      await File(
        p.join(dir.path, 'phrozen-arco', '2026-05-07T18-19-20Z-2', 'emmc.img'),
      ).exists(),
      isTrue,
    );
  });

  test('organizer preserves legacy filename timestamps', () async {
    final dir = await Directory.systemTemp.createTemp(
      'deckhand_emmc_organize_timestamp_',
    );
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    final image = File(
      p.join(dir.path, 'phrozen-arco-emmc-2026-05-04T23-02-59-557160Z.img'),
    );
    await image.writeAsBytes(List<int>.filled(1024, 1), flush: true);
    await image.setLastModified(DateTime.utc(2026, 1, 1));

    final result = await organizeLegacyEmmcBackups(dir.path);

    expect(result.moved, 1);
    expect(
      result.moves.single.toImagePath,
      p.join(dir.path, 'phrozen-arco', '2026-05-04T23-02-59Z', 'emmc.img'),
    );
  });

  test('catalog collapses manifest backups with identical hashes', () {
    final older = EmmcBackupManifest.create(
      profileId: 'phrozen-arco',
      imagePath: r'C:\Deckhand\old\emmc.img',
      imageBytes: 4096,
      imageSha256: 'f' * 64,
      disk: disk,
      deckhandVersion: 'dev',
      createdAt: DateTime.utc(2026, 5, 3, 12),
    );
    final newer = EmmcBackupManifest.create(
      profileId: 'phrozen-arco',
      imagePath: r'C:\Deckhand\new\emmc.img',
      imageBytes: 4096,
      imageSha256: 'f' * 64,
      disk: disk,
      deckhandVersion: 'dev',
      createdAt: DateTime.utc(2026, 5, 4, 12),
    );

    final catalog = buildEmmcBackupCatalog(
      manifests: [older, newer],
      candidates: const [],
    );

    expect(catalog, hasLength(1));
    expect(catalog.single.imagePath, newer.imagePath);
    expect(catalog.single.duplicatePaths, [older.imagePath]);
    expect(catalog.single.duplicateCount, 1);
    expect(catalog.single.indexed, isTrue);
  });

  test('catalog keeps unindexed candidates and labels partial images', () {
    final full = EmmcBackupImageCandidate(
      imagePath: r'C:\Deckhand\phrozen-arco\full\emmc.img',
      imageBytes: 4096,
      modifiedAt: DateTime.utc(2026, 5, 4, 12),
      inferredProfileId: 'phrozen-arco',
    );
    final partial = EmmcBackupImageCandidate(
      imagePath: r'C:\Deckhand\phrozen-arco\partial\emmc.img',
      imageBytes: 2048,
      modifiedAt: DateTime.utc(2026, 5, 4, 13),
      inferredProfileId: 'phrozen-arco',
    );

    final catalog = buildEmmcBackupCatalog(
      manifests: const [],
      candidates: [full, partial],
      referenceSizeBytes: 4096,
    );

    expect(catalog, hasLength(2));
    expect(catalog.first.imagePath, partial.imagePath);
    expect(catalog.first.fullSize, isFalse);
    expect(catalog.last.fullSize, isTrue);
    expect(catalog.every((entry) => !entry.indexed), isTrue);
  });
}
