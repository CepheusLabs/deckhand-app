import 'dart:convert';
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
      yamlText = await _getPlainWithApprovedRedirects(registryUrl);
    }
    final yaml = _loadYaml(yamlText, 'registry.yaml');
    if (yaml is! YamlMap) {
      throw const ProfileFormatException(
        'registry.yaml root must be a mapping',
      );
    }
    final profiles = yaml['profiles'];
    if (profiles is! YamlList) {
      throw const ProfileFormatException(
        'registry.yaml profiles must be a list',
      );
    }
    final entries = profiles
        .whereType<YamlMap>()
        .map(_registryEntryFromYaml)
        .whereType<ProfileRegistryEntry>()
        .toList();
    return ProfileRegistry(
      entries: await Future.wait(
        _dedupeRegistryEntries(
          entries,
        ).map((e) => _withProfileSpecFallback(e, local)),
      ),
    );
  }

  ProfileRegistryEntry? _registryEntryFromYaml(YamlMap e) {
    final id = _yamlText(e, 'id');
    final displayName = _yamlText(e, 'display_name');
    if (id == null || displayName == null) return null;
    return ProfileRegistryEntry(
      id: id,
      displayName: displayName,
      manufacturer: _yamlText(e, 'manufacturer') ?? '',
      model: _yamlText(e, 'model') ?? '',
      status: _yamlText(e, 'status') ?? 'alpha',
      directory: _yamlText(e, 'directory') ?? 'printers/$id',
      latestTag: _yamlText(e, 'latest_tag'),
      // Optional spec-card fields written by the registry generator
      // from each profile.yaml's hardware block. May be absent on
      // older registries; the picker renders an em dash.
      sbc: _yamlText(e, 'sbc'),
      kinematics: _yamlText(e, 'kinematics'),
      mcu: _yamlText(e, 'mcu'),
      extras: _yamlText(e, 'extras'),
    );
  }

  String? _yamlText(YamlMap map, String key) {
    final value = map[key];
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  List<ProfileRegistryEntry> _dedupeRegistryEntries(
    List<ProfileRegistryEntry> entries,
  ) {
    final seen = <String>{};
    final deduped = <ProfileRegistryEntry>[];
    for (final entry in entries) {
      if (seen.add(entry.id.toLowerCase())) deduped.add(entry);
    }
    return deduped;
  }

  Future<ProfileRegistryEntry> _withProfileSpecFallback(
    ProfileRegistryEntry entry,
    String? local,
  ) async {
    if (!_needsProfileSpecFallback(entry)) return entry;
    try {
      final profileText = local == null
          ? await _getRemoteProfileYaml(entry)
          : await _getLocalProfileYaml(entry, local);
      if (profileText == null) return entry;
      return _withDerivedSpecs(entry, parseProfileYaml(profileText));
    } catch (_) {
      // Registry cards are advisory. A bad or temporarily unavailable
      // profile.yaml should not block the picker from rendering.
      return entry;
    }
  }

  Future<String?> _getLocalProfileYaml(
    ProfileRegistryEntry entry,
    String local,
  ) async {
    final root = p.normalize(p.absolute(local));
    final path = p.normalize(
      p.absolute(p.join(root, entry.directory, 'profile.yaml')),
    );
    if (!p.isWithin(root, path)) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  Future<String?> _getRemoteProfileYaml(ProfileRegistryEntry entry) async {
    final profileUrl = _remoteProfileYamlUrl(entry);
    if (profileUrl == null) return null;
    return _getPlainWithApprovedRedirects(profileUrl.toString());
  }

  Uri? _remoteProfileYamlUrl(ProfileRegistryEntry entry) {
    final directory = entry.directory.trim();
    if (directory.isEmpty ||
        directory.contains('\\') ||
        directory.startsWith('/') ||
        directory.split('/').any((part) => part == '..') ||
        Uri.tryParse(directory)?.hasScheme == true) {
      return null;
    }
    final base = Uri.parse(registryUrl);
    final dir = directory.endsWith('/') ? directory : '$directory/';
    return base.resolve('${dir}profile.yaml');
  }

  bool _needsProfileSpecFallback(ProfileRegistryEntry entry) =>
      _isBlank(entry.sbc) || _isBlank(entry.kinematics) || _isBlank(entry.mcu);

  bool _isBlank(String? value) => value == null || value.trim().isEmpty;

  ProfileRegistryEntry _withDerivedSpecs(
    ProfileRegistryEntry entry,
    PrinterProfile profile,
  ) {
    return ProfileRegistryEntry(
      id: entry.id,
      displayName: entry.displayName,
      manufacturer: entry.manufacturer,
      model: entry.model,
      status: entry.status,
      directory: entry.directory,
      latestTag: entry.latestTag,
      sbc: _firstText(entry.sbc, _deriveSbc(profile)),
      kinematics: _firstText(entry.kinematics, _deriveKinematics(profile)),
      mcu: _firstText(entry.mcu, _deriveMcu(profile)),
      extras: _firstText(
        entry.extras,
        _optionalText(profile.raw['picker_extras']),
      ),
    );
  }

  String? _firstText(String? primary, String? fallback) =>
      !_isBlank(primary) ? primary!.trim() : fallback?.trim();

  String? _optionalText(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  String? _deriveSbc(PrinterProfile profile) {
    final soc = profile.hardware.sbc?.soc;
    if (soc == null || soc.isEmpty) return null;
    final parts = soc.split('-');
    if (parts.length == 1) return parts[0].toUpperCase();
    final vendor = parts.first;
    final chip = parts.sublist(1).join(' ').toUpperCase();
    if (vendor == 'rockchip') return chip;
    return '${_titleCase(vendor)} $chip';
  }

  String? _deriveKinematics(PrinterProfile profile) {
    final kin = profile.hardware.kinematics;
    if (kin == null || kin.isEmpty) return null;
    return switch (kin) {
      'corexy' => 'CoreXY',
      'corexz' => 'CoreXZ',
      'cartesian' => 'Cartesian',
      'delta' => 'Delta',
      'scara' => 'SCARA',
      _ => _titleCase(kin),
    };
  }

  String? _deriveMcu(PrinterProfile profile) {
    if (profile.mcus.isEmpty) return null;
    final main = profile.mcus.firstWhere(
      (mcu) => mcu.id == 'main',
      orElse: () => profile.mcus.first,
    );
    final chip = main.raw['chip'];
    if (chip is! String || chip.isEmpty) return null;
    return chip.replaceFirst(RegExp(r'[a-z]+$'), '').toUpperCase();
  }

  String _titleCase(String value) {
    if (value.isEmpty) return value;
    return value[0].toUpperCase() + value.substring(1);
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
    final dest = p.join(
      paths.cacheDir,
      'profiles',
      _repoCacheKey(),
      resolvedRef,
    );

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
    final localPath = _profilesFetchText(res, 'local_path');
    return ProfileCacheEntry(
      profileId: profileId,
      ref: resolvedRef,
      localPath: p.join(localPath, 'printers', profileId),
      resolvedSha: _optionalText(res['resolved_sha']) ?? '',
    );
  }

  String _profilesFetchText(Map<String, dynamic> response, String key) {
    final value = _optionalText(response[key]);
    if (value == null) {
      throw ProfileFormatException('profiles.fetch returned invalid `$key`');
    }
    return value;
  }

  /// A ref matches this pattern when it looks like a semver-y tag
  /// (`v1.2.3`, `v26.4.18-1247`, `1.0.0`). Anything else is treated as a
  /// mutable branch/HEAD-like reference and cached accordingly.
  static final _tagLike = RegExp(r'^v?\d+\.\d+\.\d+(-[\w.-]+)?$');
  bool _looksLikeTag(String ref) => _tagLike.hasMatch(ref);

  String _repoCacheKey() {
    final parsed = Uri.tryParse(profilesRepo);
    final readable = parsed == null || parsed.host.isEmpty
        ? 'custom'
        : '${parsed.host}${parsed.path}'.toLowerCase();
    final compact = readable
        .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    if (compact.isNotEmpty && compact.length <= 80) return compact;
    return base64Url.encode(utf8.encode(profilesRepo)).replaceAll('=', '');
  }

  Future<String> _getPlainWithApprovedRedirects(String url) async {
    var current = Uri.parse(url);
    for (var redirects = 0; redirects < 5; redirects++) {
      await requireHostApproved(_security, current.toString());
      final res = await _dio.get<String>(
        current.toString(),
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: false,
          validateStatus: (status) =>
              status != null && (status < 400 || _isRedirect(status)),
        ),
      );
      if (!_isRedirect(res.statusCode)) return res.data ?? '';
      current = _resolveRedirect(current, res.headers);
    }
    throw const ProfileFormatException(
      'too many redirects while fetching registry.yaml',
    );
  }

  Uri _resolveRedirect(Uri current, Headers headers) {
    final location = headers.value('location');
    if (location == null || location.trim().isEmpty) {
      throw ProfileFormatException(
        'redirect from $current did not include Location',
      );
    }
    final next = current.resolve(location);
    if (next.scheme != 'https' || next.host.isEmpty) {
      throw const ProfileFormatException(
        'profile registry redirects must use https',
      );
    }
    return next;
  }

  bool _isRedirect(int? status) =>
      status == 301 ||
      status == 302 ||
      status == 303 ||
      status == 307 ||
      status == 308;

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
  final yaml = _loadYaml(yamlText, 'profile.yaml');
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
  try {
    return PrinterProfile.fromJson(raw);
  } on ProfileFormatException {
    rethrow;
  } catch (e) {
    throw ProfileFormatException('profile.yaml has invalid structure: $e');
  }
}

Object? _loadYaml(String yamlText, String label) {
  try {
    return loadYaml(yamlText);
  } catch (e) {
    throw ProfileFormatException('$label is not valid YAML: $e');
  }
}

// yaml's YamlMap/YamlList aren't directly serializable; convert into
// pure Dart Map/List for downstream models.
Object? _deepConvert(Object? node) {
  if (node is YamlMap) {
    final out = <String, dynamic>{};
    for (final entry in node.entries) {
      final key = entry.key;
      if (key is! String) {
        throw const ProfileFormatException(
          'profile.yaml mapping keys must be strings',
        );
      }
      out[key] = _deepConvert(entry.value);
    }
    return out;
  }
  if (node is YamlList) {
    return node.map(_deepConvert).toList();
  }
  return node;
}
