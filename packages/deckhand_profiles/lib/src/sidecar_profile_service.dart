import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_flash/deckhand_flash.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// [ProfileService] that:
///   - Fetches `registry.yaml` over HTTPS from a configured repo URL, OR
///     reads it from a local directory if [localProfilesDir] is set.
///   - Uses the Go sidecar to shallow-clone individual profile tags
///     (go-git from the sidecar), bypassed when [localProfilesDir] is set.
///   - Parses profile.yaml into an in-memory map keyed lookup model.
///
/// **Local-dir override.** If the environment variable
/// `DECKHAND_PROFILES_LOCAL` is set (or [localProfilesDir] is passed
/// directly), the service reads `registry.yaml` and `printers/<id>/` from
/// that directory and skips all network fetches. Intended for profile
/// authoring and local testing before a deckhand-profiles release is cut.
///
/// The local-dir override is **dev-only**: in AOT-compiled release builds
/// (`dart.vm.product` = true) both the env var and direct
/// [localProfilesDir] parameter are ignored, so a hostile environment
/// or settings file cannot bypass the signed-tag chain. The app may
/// explicitly opt local smoke releases back in with
/// [allowLocalProfilesInProduct]; production wiring must leave it false.
class SidecarProfileService implements ProfileService {
  SidecarProfileService({
    required this.sidecar,
    required this.paths,
    required SecurityService security,
    this.registryUrl =
        'https://raw.githubusercontent.com/CepheusLabs/deckhand-profiles/main/registry.yaml',
    this.profilesRepo = 'https://github.com/CepheusLabs/deckhand-profiles.git',
    String? localProfilesDir,
    Dio? dio,
    TrustKeyring? trustKeyring,
    bool requireSignedTag = false,
    bool allowLocalProfilesInProduct = false,
  }) : _security = security,
       _dio = (dio ?? Dio())..interceptors.add(EgressLogInterceptor(security)),
       _trustKeyring = trustKeyring,
       _requireSignedTag = requireSignedTag,
       localProfilesDir = _effectiveLocalProfilesDir(
         localProfilesDir,
         allowLocalProfilesInProduct: allowLocalProfilesInProduct,
       );

  /// Reads local profile overrides only in non-release builds unless
  /// [allowLocalProfilesInProduct] is true for an explicit local smoke
  /// release. Normal release builds (`dart compile exe`,
  /// `flutter build --release`) compile out to `null` regardless of
  /// env vars or constructor arguments.
  static String? _effectiveLocalProfilesDir(
    String? explicit, {
    bool allowLocalProfilesInProduct = false,
  }) {
    const isRelease = bool.fromEnvironment(
      'dart.vm.product',
      defaultValue: false,
    );
    if (isRelease && !allowLocalProfilesInProduct) return null;
    return explicit ?? Platform.environment['DECKHAND_PROFILES_LOCAL'];
  }

  final SidecarConnection sidecar;
  final DeckhandPaths paths;
  final String registryUrl;
  final String profilesRepo;
  final String? localProfilesDir;
  final SecurityService _security;
  final Dio _dio;
  final TrustKeyring? _trustKeyring;
  final bool _requireSignedTag;

  @override
  Future<ProfileRegistry> fetchRegistry({bool force = false}) async {
    final local = localProfilesDir;
    final String yamlText;
    if (local != null) {
      final f = File(p.join(local, 'registry.yaml'));
      if (!await f.exists()) {
        throw StateError(
          'DECKHAND_PROFILES_LOCAL is set to "$local" but '
          '${f.path} was not found',
        );
      }
      yamlText = await f.readAsString();
    } else {
      await requireHostApproved(_security, registryUrl);
      final res = await _dio.get<String>(
        registryUrl,
        options: Options(responseType: ResponseType.plain),
      );
      yamlText = res.data ?? '';
    }
    final yaml = loadYaml(yamlText) as YamlMap;
    final entries = (yaml['profiles'] as YamlList? ?? YamlList())
        .map((e) => (e as YamlMap))
        .map(
          (e) => ProfileRegistryEntry(
            id: e['id'] as String,
            displayName: e['display_name'] as String,
            manufacturer: e['manufacturer'] as String? ?? '',
            model: e['model'] as String? ?? '',
            status: e['status'] as String? ?? 'alpha',
            directory: e['directory'] as String? ?? 'printers/${e['id']}',
            latestTag: e['latest_tag'] as String?,
            // Optional spec-card fields written by the registry
            // generator from each profile.yaml's hardware block. May
            // be absent on older registries — the picker tolerates
            // null and renders "—" in the corresponding spec cell.
            sbc: e['sbc'] as String?,
            kinematics: e['kinematics'] as String?,
            mcu: e['mcu'] as String?,
            extras: e['extras'] as String?,
          ),
        )
        .toList();
    return ProfileRegistry(entries: entries);
  }

  @override
  Future<ProfileCacheEntry> ensureCached({
    required String profileId,
    String? ref,
    bool force = false,
  }) async {
    _validateProfileId(profileId);
    final local = localProfilesDir;
    if (local != null) {
      final printerDir = p.join(local, 'printers', profileId);
      if (!await Directory(printerDir).exists()) {
        throw StateError(
          'DECKHAND_PROFILES_LOCAL is set to "$local" but '
          '$printerDir was not found',
        );
      }
      return ProfileCacheEntry(
        profileId: profileId,
        ref: 'local',
        localPath: printerDir,
        resolvedSha: 'local',
      );
    }

    final resolvedRef = ref ?? 'main';
    _validateGitRef(resolvedRef);
    final dest = p.join(paths.cacheDir, 'profiles', resolvedRef);

    // Semver-tagged refs (v1.2.3, v26.4.18-1247) are immutable - a tag
    // pointing at a given commit never moves, so caching by ref name is
    // safe. Branch refs like `main` ARE mutable; caching them by name
    // causes users to see whatever snapshot was pulled first, forever.
    // Invalidate those before every fetch. `force` overrides immutable
    // caching too, for the "I just pushed a profile fix and need it
    // NOW" case.
    final isImmutableRef = _looksLikeTag(resolvedRef);
    final keyring = _trustKeyring;
    final mustVerifyCachedRef =
        isImmutableRef && !force && keyring != null && !keyring.isPlaceholder;
    if (await Directory(dest).exists()) {
      if (isImmutableRef && !force && !mustVerifyCachedRef) {
        return ProfileCacheEntry(
          profileId: profileId,
          ref: resolvedRef,
          localPath: p.join(dest, 'printers', profileId),
          resolvedSha: '',
        );
      }
      if (!mustVerifyCachedRef) {
        try {
          await Directory(dest).delete(recursive: true);
        } catch (_) {
          // Best-effort - if the directory is locked, the sidecar clone
          // will fail anyway and surface a clearer error.
        }
      }
    }

    await requireHostApproved(_security, profilesRepo);
    final params = <String, dynamic>{
      'repo_url': profilesRepo,
      'ref': resolvedRef,
      'dest': dest,
    };
    if (keyring != null && !keyring.isPlaceholder) {
      // Production wiring path: the bundled keyring is real, so we
      // forward it on every fetch. The sidecar verifies signed tags
      // against this material and surfaces unsigned_or_untrusted as
      // a typed error the UI hard-stops on.
      params['trusted_keys'] = keyring.armored;
      if (_requireSignedTag) {
        params['require_signed_tag'] = true;
      }
    }
    final res = await sidecar.call('profiles.fetch', params);
    return ProfileCacheEntry(
      profileId: profileId,
      ref: resolvedRef,
      localPath: p.join(res['local_path'] as String, 'printers', profileId),
      resolvedSha: res['resolved_sha'] as String? ?? '',
    );
  }

  /// A ref matches this pattern when it looks like a semver-y tag
  /// (`v1.2.3`, `v26.4.18-1247`, `1.0.0`). Anything else is treated as a
  /// mutable branch/HEAD-like reference and cached accordingly.
  static final _tagLike = RegExp(r'^v?\d+\.\d+\.\d+(-[\w.-]+)?$');
  bool _looksLikeTag(String ref) => _tagLike.hasMatch(ref);

  @override
  Future<PrinterProfile> load(ProfileCacheEntry cacheEntry) async {
    final file = File(p.join(cacheEntry.localPath, 'profile.yaml'));
    final text = await file.readAsString();
    return parseProfileYaml(text);
  }

  void _validateProfileId(String profileId) {
    if (!RegExp(r'^[a-z0-9-]+$').hasMatch(profileId)) {
      throw ProfileFormatException('unsafe profile id "$profileId"');
    }
  }

  void _validateGitRef(String ref) {
    if (ref.isEmpty ||
        ref.startsWith('-') ||
        ref.startsWith('/') ||
        ref.contains('..') ||
        ref.contains('\\') ||
        !RegExp(r'^[A-Za-z0-9._/-]+$').hasMatch(ref)) {
      throw ProfileFormatException('unsafe profile ref "$ref"');
    }
  }
}

/// Thrown when a profile.yaml is missing the fields the wizard treats
/// as load-bearing. Surfaces a readable message instead of the raw
/// cast/null error a downstream model would otherwise emit.
class ProfileFormatException implements Exception {
  const ProfileFormatException(this.message);
  final String message;
  @override
  String toString() => 'ProfileFormatException: $message';
}

/// Parse a profile.yaml string into a [PrinterProfile].
///
/// Separated from [SidecarProfileService.load] so unit tests can
/// exercise the parsing contract without going through File I/O.
///
/// Contract:
///   - A profile missing `schema_version` OR `profile_id` throws a
///     [ProfileFormatException] with a message that names the missing
///     field. This lets the wizard refuse to proceed on half-migrated
///     profiles instead of bricking a printer with an empty id.
///   - Unknown keys are preserved in [PrinterProfile.raw] (forward
///     compatibility with future profile versions).
///   - `status: stub` parses as [ProfileStatus.stub] so the wizard can
///     refuse to run it.
PrinterProfile parseProfileYaml(String yamlText) {
  final yaml = loadYaml(yamlText);
  if (yaml is! YamlMap) {
    throw const ProfileFormatException('profile.yaml root must be a mapping');
  }
  final raw = _deepConvert(yaml) as Map<String, dynamic>;
  if (!raw.containsKey('schema_version')) {
    throw const ProfileFormatException(
      'profile.yaml is missing required field `schema_version`',
    );
  }
  final pid = raw['profile_id'];
  if (pid is! String || pid.isEmpty) {
    throw const ProfileFormatException(
      'profile.yaml is missing required field `profile_id`',
    );
  }
  return PrinterProfile.fromJson(raw);
}

// yaml's YamlMap/YamlList aren't directly serializable; convert into
// pure Dart Map/List for downstream models.
Object? _deepConvert(Object? node) {
  if (node is YamlMap) {
    return Map<String, dynamic>.fromEntries(
      node.entries.map(
        (e) => MapEntry(e.key.toString(), _deepConvert(e.value)),
      ),
    );
  }
  if (node is YamlList) {
    return node.map(_deepConvert).toList();
  }
  return node;
}
