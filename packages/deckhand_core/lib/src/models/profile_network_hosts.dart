import 'dart:collection';

import '../services/security_service.dart';
import 'printer_profile.dart';

/// Normalize a profile-declared host or URL into the network-approval key.
///
/// Returns null for blank values, path-shaped strings, malformed host
/// labels, and non-HTTP URL syntax.
String? normalizeHostCandidate(String value) {
  var raw = value.trim().toLowerCase();
  if (raw.isEmpty) return null;
  final fromUrl = hostFromUrl(raw);
  if (fromUrl != null) return fromUrl;
  if (raw.contains('://') || raw.contains('/') || raw.contains('\\')) {
    return null;
  }
  if (raw.endsWith('.')) raw = raw.substring(0, raw.length - 1);
  if (raw.isEmpty || raw.contains('..')) return null;
  if (!RegExp(
    r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$',
  ).hasMatch(raw)) {
    return null;
  }
  return raw;
}

/// Non-printer network hosts a profile can cause Deckhand to contact.
///
/// This powers a single profile-level approval prompt. The lower-level
/// egress checks still enforce the same approval gate at request time, so
/// redirects and newly-added hosts cannot bypass approval.
List<String> profileNetworkHosts(PrinterProfile profile) {
  final hosts = SplayTreeSet<String>();
  void addCandidate(String? value) {
    if (value == null) return;
    final host = normalizeHostCandidate(value);
    if (host != null) hosts.add(host);
  }

  for (final host in profile.requiredHosts) {
    addCandidate(host);
  }
  for (final option in profile.os.freshInstallOptions) {
    addCandidate(option.url);
    if (_isGithubReleaseDownloadUrl(option.url)) {
      hosts.addAll(_githubReleaseHosts);
    }
  }
  for (final firmware in profile.firmware.choices) {
    addCandidate(firmware.repo);
  }
  for (final component in _stackComponents(profile.stack)) {
    addCandidate(component['repo'] as String?);
    addCandidate(component['url'] as String?);
    if (component['release_repo'] is String) {
      hosts.addAll(_githubReleaseHosts);
    }
  }

  return hosts.toList(growable: false);
}

Iterable<Map<String, dynamic>> _stackComponents(StackConfig stack) sync* {
  for (final component in [stack.moonraker, stack.kiauh, stack.crowsnest]) {
    if (component != null) yield component;
  }
  final webuiChoices = (stack.webui?['choices'] as List?) ?? const [];
  for (final choice in webuiChoices.whereType<Map>()) {
    yield _stringKeyMap(choice);
  }
}

Map<String, dynamic> _stringKeyMap(Map value) {
  final out = <String, dynamic>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is String) out[key] = entry.value;
  }
  return out;
}

bool _isGithubReleaseDownloadUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null || uri.host.toLowerCase() != 'github.com') return false;
  final segments = uri.pathSegments;
  return segments.length >= 5 &&
      segments[2] == 'releases' &&
      segments[3] == 'download';
}

const _githubReleaseHosts = [
  'api.github.com',
  'github.com',
  'github-releases.githubusercontent.com',
  'objects.githubusercontent.com',
  'release-assets.githubusercontent.com',
];
