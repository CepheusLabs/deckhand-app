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
}
