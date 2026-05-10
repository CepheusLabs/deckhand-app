import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const String osImageDownloadManifestSuffix = '.deckhand-download.json';

class OsImageCacheEntry {
  const OsImageCacheEntry({
    required this.imagePath,
    required this.bytes,
    required this.modifiedAt,
    this.url,
    this.expectedSha256,
    this.actualSha256,
    this.downloadedAt,
    this.reusedAt,
    this.manifestPath,
  });

  final String imagePath;
  final int bytes;
  final DateTime modifiedAt;
  final String? url;
  final String? expectedSha256;
  final String? actualSha256;
  final DateTime? downloadedAt;
  final DateTime? reusedAt;
  final String? manifestPath;

  bool get hasManifest => manifestPath != null;

  bool get hasValidSha256 =>
      _isSha256(expectedSha256) && _isSha256(actualSha256);

  bool get hashMatchesManifest =>
      hasValidSha256 &&
      (_isCompressedArtifactUrl(url) || expectedSha256 == actualSha256);

  DateTime get lastTouchedAt => reusedAt ?? downloadedAt ?? modifiedAt;

  String get fileName => p.basename(imagePath);
}

Future<List<OsImageCacheEntry>> scanOsImageCache(String root) async {
  final dir = Directory(root);
  final type = await FileSystemEntity.type(root, followLinks: false);
  if (type == FileSystemEntityType.notFound) return const [];
  if (type != FileSystemEntityType.directory) {
    throw FileSystemException('OS image cache must be a directory', root);
  }
  final entries = <OsImageCacheEntry>[];
  await for (final entity in dir.list(followLinks: false)) {
    if (entity is! File) continue;
    final path = entity.path;
    final name = p.basename(path);
    if (name.endsWith(osImageDownloadManifestSuffix) ||
        name.endsWith('$osImageDownloadManifestSuffix.tmp') ||
        name.endsWith('.part')) {
      continue;
    }
    final fileType = await FileSystemEntity.type(path, followLinks: false);
    if (fileType != FileSystemEntityType.file) continue;
    final stat = await entity.stat();
    if (stat.size <= 0) continue;
    final manifest = await _readOsImageManifest(path);
    entries.add(
      OsImageCacheEntry(
        imagePath: path,
        bytes: stat.size,
        modifiedAt: stat.modified,
        url: manifest?.url,
        expectedSha256: manifest?.expectedSha256,
        actualSha256: manifest?.actualSha256,
        downloadedAt: manifest?.downloadedAt,
        reusedAt: manifest?.reusedAt,
        manifestPath: manifest?.path,
      ),
    );
  }
  entries.sort((a, b) => b.lastTouchedAt.compareTo(a.lastTouchedAt));
  return entries;
}

Future<void> deleteOsImageCacheEntry({
  required String root,
  required String imagePath,
}) async {
  final safeRoot = p.normalize(p.absolute(root));
  final safeImage = p.normalize(p.absolute(imagePath));
  if (!p.isWithin(safeRoot, safeImage)) {
    throw FileSystemException(
      'OS image is outside the managed cache',
      imagePath,
    );
  }
  final imageType = await FileSystemEntity.type(safeImage, followLinks: false);
  if (imageType == FileSystemEntityType.link ||
      imageType == FileSystemEntityType.directory) {
    throw FileSystemException(
      'OS image cache entry must be a regular file',
      imagePath,
    );
  }
  if (imageType == FileSystemEntityType.file) {
    await File(safeImage).delete();
  }
  for (final related in <String>[
    '$safeImage.part',
    '$safeImage.download.part',
    '$safeImage$osImageDownloadManifestSuffix',
    '$safeImage$osImageDownloadManifestSuffix.tmp',
  ]) {
    final type = await FileSystemEntity.type(related, followLinks: false);
    if (type == FileSystemEntityType.file) {
      await File(related).delete();
    } else if (type == FileSystemEntityType.link ||
        type == FileSystemEntityType.directory) {
      throw FileSystemException(
        'OS image cache metadata must be a regular file',
        related,
      );
    }
  }
}

Future<int> clearOsImageCache(String root) async {
  final safeRoot = p.normalize(p.absolute(root));
  final rootType = await FileSystemEntity.type(safeRoot, followLinks: false);
  if (rootType == FileSystemEntityType.notFound) return 0;
  if (rootType != FileSystemEntityType.directory) {
    throw FileSystemException('OS image cache must be a directory', root);
  }
  var deleted = 0;
  await for (final entity in Directory(safeRoot).list(followLinks: false)) {
    final type = await FileSystemEntity.type(entity.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) continue;
    if (type != FileSystemEntityType.file) {
      throw FileSystemException(
        'OS image cache entries must be regular files',
        entity.path,
      );
    }
    await File(entity.path).delete();
    deleted++;
  }
  return deleted;
}

Future<int> pruneOsImageCache({
  required String root,
  required DateTime olderThan,
}) async {
  final entries = await scanOsImageCache(root);
  var deleted = 0;
  for (final entry in entries) {
    if (!entry.lastTouchedAt.isBefore(olderThan)) continue;
    await deleteOsImageCacheEntry(root: root, imagePath: entry.imagePath);
    deleted++;
  }
  deleted += await _pruneStaleOsImageTempFiles(
    root: root,
    olderThan: olderThan,
  );
  return deleted;
}

Future<int> _pruneStaleOsImageTempFiles({
  required String root,
  required DateTime olderThan,
}) async {
  final safeRoot = p.normalize(p.absolute(root));
  final rootType = await FileSystemEntity.type(safeRoot, followLinks: false);
  if (rootType == FileSystemEntityType.notFound) return 0;
  if (rootType != FileSystemEntityType.directory) {
    throw FileSystemException('OS image cache must be a directory', root);
  }

  var deleted = 0;
  await for (final entity in Directory(safeRoot).list(followLinks: false)) {
    final name = p.basename(entity.path);
    if (!_isOsImageTempName(name)) continue;
    final type = await FileSystemEntity.type(entity.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) continue;
    if (type != FileSystemEntityType.file) {
      throw FileSystemException(
        'OS image cache temp entries must be regular files',
        entity.path,
      );
    }
    final stat = await File(entity.path).stat();
    if (!stat.modified.isBefore(olderThan)) continue;
    await File(entity.path).delete();
    deleted++;
  }
  return deleted;
}

bool _isOsImageTempName(String name) =>
    name.endsWith('.part') ||
    name.endsWith('$osImageDownloadManifestSuffix.tmp');

Future<_OsImageManifest?> _readOsImageManifest(String imagePath) async {
  final manifestPath = '$imagePath$osImageDownloadManifestSuffix';
  final type = await FileSystemEntity.type(manifestPath, followLinks: false);
  if (type == FileSystemEntityType.notFound) return null;
  if (type != FileSystemEntityType.file) return null;
  try {
    final raw = jsonDecode(await File(manifestPath).readAsString());
    final map = _stringKeyMap(raw);
    if (map == null) return null;
    return _OsImageManifest(
      path: manifestPath,
      url: _jsonString(map['url']),
      expectedSha256: _normalizedSha(map['expected_sha256']),
      actualSha256: _normalizedSha(map['actual_sha256']),
      downloadedAt: _parseDate(map['downloaded_at']),
      reusedAt: _parseDate(map['reused_at']),
    );
  } catch (_) {
    return null;
  }
}

class _OsImageManifest {
  const _OsImageManifest({
    required this.path,
    this.url,
    this.expectedSha256,
    this.actualSha256,
    this.downloadedAt,
    this.reusedAt,
  });

  final String path;
  final String? url;
  final String? expectedSha256;
  final String? actualSha256;
  final DateTime? downloadedAt;
  final DateTime? reusedAt;
}

String? _normalizedSha(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim().toLowerCase();
  return _isSha256(normalized) ? normalized : null;
}

bool _isSha256(String? value) {
  if (value == null) return false;
  return RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
}

bool _isCompressedArtifactUrl(String? value) {
  if (value == null) return false;
  final uri = Uri.tryParse(value);
  final path = uri?.path ?? value;
  return path.toLowerCase().endsWith('.xz');
}

DateTime? _parseDate(Object? value) {
  if (value is! String) return null;
  return DateTime.tryParse(value);
}

String? _jsonString(Object? value) => value is String ? value : null;

Map<String, dynamic>? _stringKeyMap(Object? value) {
  if (value is! Map) return null;
  final out = <String, dynamic>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is String) out[key] = entry.value;
  }
  return out;
}
