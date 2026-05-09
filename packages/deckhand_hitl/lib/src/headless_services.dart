import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:path/path.dart' as p;
import 'package:meta/meta.dart';

/// In-process [SecurityService] for the HITL driver. **CI-only.**
///
/// `DefaultSecurityService` (in deckhand_flash) uses
/// flutter_secure_storage, which requires WidgetsFlutterBinding to
/// initialise platform plugins — no good for a CLI binary. This
/// implementation persists approved network hosts and SSH fingerprint
/// pins to a JSON file under [stateDir] so reruns within the same
/// rig are stable, but never tries to talk to a keychain.
///
/// **Do not import from non-HITL code.** The class auto-approves
/// every host passed to [requestHostApprovals] and pre-allows
/// `github.com` / `raw.githubusercontent.com` / `api.github.com` /
/// `objects.githubusercontent.com` without prompting. That's
/// correct for a controlled rig and devastating in production.
/// The class is `@internal` so a `dart analyze` against the
/// `meta` lints flags any cross-package import. The package's
/// public barrel ([package:deckhand_hitl/deckhand_hitl.dart])
/// deliberately does not export this file; importing it requires
/// a `src/` path that's loud at the call site.
@internal
class HeadlessSecurityService implements SecurityService {
  HeadlessSecurityService({
    required this.stateDir,
    Iterable<String> preApproveHosts = const [
      'github.com',
      'raw.githubusercontent.com',
      'api.github.com',
      'objects.githubusercontent.com',
    ],
  }) {
    for (final h in preApproveHosts) {
      _allowedHosts.add(h.toLowerCase());
    }
    _load();
  }

  final String stateDir;

  final _allowedHosts = <String>{};
  final _fingerprints = <String, String>{};
  final _tokens = <String, _TokenRecord>{};
  final _egressController = StreamController<EgressEvent>.broadcast();
  int _tokenCounter = 0;

  String get _allowlistPath => p.join(stateDir, 'allowlist.json');
  String get _fingerprintPath => p.join(stateDir, 'known_hosts.json');

  void _load() {
    final allowFile = File(_allowlistPath);
    if (allowFile.existsSync()) {
      try {
        final data = jsonDecode(allowFile.readAsStringSync());
        if (data is List) {
          for (final h in data) {
            _allowedHosts.add(h.toString().toLowerCase());
          }
        }
      } on FormatException {
        // ignore, next save will overwrite
      }
    }
    final fpFile = File(_fingerprintPath);
    if (fpFile.existsSync()) {
      try {
        final data = jsonDecode(fpFile.readAsStringSync());
        if (data is Map) {
          data.forEach((k, v) => _fingerprints[k.toString()] = v.toString());
        }
      } on FormatException {
        // ignore
      }
    }
  }

  void _persistAllowlist() {
    final f = File(_allowlistPath);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(jsonEncode(_allowedHosts.toList()..sort()));
  }

  void _persistFingerprints() {
    final f = File(_fingerprintPath);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(jsonEncode(_fingerprints));
  }

  @override
  Future<ConfirmationToken> issueConfirmationToken({
    required String operation,
    required String target,
    Duration ttl = const Duration(seconds: 60),
  }) async {
    _tokenCounter++;
    final value =
        'hitl-token-$_tokenCounter-${DateTime.now().microsecondsSinceEpoch}';
    final expires = DateTime.now().add(ttl);
    _tokens[value] = _TokenRecord(
      operation: operation,
      target: target,
      expiresAt: expires,
    );
    return ConfirmationToken(
      value: value,
      expiresAt: expires,
      operation: operation,
      target: target,
    );
  }

  /// Validate + consume a token. Mirrors DefaultSecurityService's
  /// helper of the same name; the elevated-helper path expects the
  /// token to be invalid after one use.
  @override
  bool consumeToken(String value, String operation, {required String target}) {
    final t = _tokens.remove(value);
    if (t == null) return false;
    if (t.operation != operation) return false;
    if (t.target != target) return false;
    if (DateTime.now().isAfter(t.expiresAt)) return false;
    return true;
  }

  @override
  Future<bool> isHostAllowed(String host) async =>
      _allowedHosts.contains(host.toLowerCase());

  @override
  Future<void> approveHost(String host) async {
    _allowedHosts.add(host.toLowerCase());
    _persistAllowlist();
  }

  @override
  Future<void> revokeHost(String host) async {
    _allowedHosts.remove(host.toLowerCase());
    _persistAllowlist();
  }

  @override
  Future<Map<String, bool>> requestHostApprovals(List<String> hosts) async {
    // In CI we auto-approve every host the profile declares — the
    // rig is a controlled environment, and a missed approval would
    // make the driver hang on the very first egress. Production
    // wiring opts users into each new host explicitly.
    final out = <String, bool>{};
    for (final h in hosts) {
      final lower = h.toLowerCase();
      _allowedHosts.add(lower);
      out[h] = true;
    }
    _persistAllowlist();
    return out;
  }

  @override
  Future<void> pinHostFingerprint({
    required String host,
    required String fingerprint,
  }) async {
    _fingerprints[host] = fingerprint;
    _persistFingerprints();
  }

  @override
  Future<String?> pinnedHostFingerprint(String host) async =>
      _fingerprints[host];

  @override
  Future<void> forgetHostFingerprint(String host) async {
    _fingerprints.remove(host);
    _persistFingerprints();
  }

  @override
  Future<Map<String, String>> listPinnedFingerprints() async =>
      Map<String, String>.from(_fingerprints);

  @override
  Future<List<String>> listApprovedHosts() async {
    final hosts = _allowedHosts.toList()..sort();
    return hosts;
  }

  @override
  Future<String?> getGitHubToken() async => _githubToken;

  @override
  Future<void> setGitHubToken(String? token) async {
    _githubToken = (token == null || token.trim().isEmpty)
        ? null
        : token.trim();
  }

  String? _githubToken;

  @override
  Stream<EgressEvent> get egressEvents => _egressController.stream;

  @override
  void recordEgress(EgressEvent event) {
    if (_egressController.isClosed) return;
    _egressController.add(event);
  }

  Future<void> dispose() async {
    if (!_egressController.isClosed) {
      await _egressController.close();
    }
  }
}

class _TokenRecord {
  _TokenRecord({
    required this.operation,
    required this.target,
    required this.expiresAt,
  });
  final String operation;
  final String target;
  final DateTime expiresAt;
}

/// Stub [DiscoveryService] for HITL. **CI-only.** The driver always
/// knows the printer's IP up front (it's in the scenario YAML), so
/// mDNS scan is never invoked. If the wizard asks anyway, return
/// an empty list rather than calling Bonsoir (which needs platform
/// plugins). `waitForSsh` falls back to a plain TCP-connect probe
/// so the first-boot poll path still works. See the comment on
/// [HeadlessSecurityService] for why this is `@internal`.
@internal
class StubDiscoveryService implements DiscoveryService {
  @override
  Future<List<DiscoveredPrinter>> scanMdns({
    Duration timeout = const Duration(seconds: 5),
  }) async => const [];

  @override
  Future<List<DiscoveredPrinter>> scanCidr({
    required String cidr,
    int port = 7125,
    Duration timeout = const Duration(seconds: 5),
  }) async => const [];

  @override
  Future<bool> waitForSsh({
    required String host,
    int port = 22,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final s = await Socket.connect(
          host,
          port,
          timeout: const Duration(seconds: 5),
        );
        s.destroy();
        return true;
      } on SocketException {
        await Future<void>.delayed(const Duration(seconds: 5));
      }
    }
    return false;
  }
}

/// Stub [MoonrakerService] — **CI-only.** The wizard's status
/// probes against Moonraker aren't load-bearing for the install
/// path itself; HITL can safely return empty data. If a profile
/// step *does* need Moonraker the runner surfaces the resulting
/// assertion failure as a scenario error. See the comment on
/// [HeadlessSecurityService] for why this is `@internal`.
@internal
@immutable
class StubMoonrakerService implements MoonrakerService {
  const StubMoonrakerService();

  @override
  Future<KlippyInfo> info({required String host, int port = 7125}) async {
    throw const _StubUnavailable('moonraker.info');
  }

  @override
  Future<bool> isPrinting({required String host, int port = 7125}) async =>
      false;

  @override
  Future<Map<String, dynamic>> queryObjects({
    required String host,
    int port = 7125,
    required List<String> objects,
  }) async {
    throw const _StubUnavailable('moonraker.queryObjects');
  }

  @override
  Future<void> runGCode({
    required String host,
    int port = 7125,
    required String script,
  }) async {
    throw const _StubUnavailable('moonraker.runGCode');
  }

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

class _StubUnavailable implements Exception {
  const _StubUnavailable(this.method);
  final String method;
  @override
  String toString() => 'moonraker stub: $method not implemented for HITL';
}
