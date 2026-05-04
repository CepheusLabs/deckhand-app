/// Confirmation tokens for destructive operations, host allow-list
/// management, and known-host fingerprints.
abstract class SecurityService {
  /// Issue a single-use token for [operation] targeting [target].
  /// The controller consumes the token immediately before launching
  /// the privileged helper, after the live disk safety check passes.
  /// The helper treats the value as a launch nonce only; it cannot
  /// independently enforce SecurityService TTL/reuse semantics.
  Future<ConfirmationToken> issueConfirmationToken({
    required String operation,
    required String target,
    Duration ttl = const Duration(seconds: 60),
  });

  /// Mark [value] as consumed, removing it from the live-token set so
  /// any subsequent attempt to use the same value fails. Callers
  /// invoke this immediately after handing the token to a privileged
  /// helper — by that point the UI flow has done its job and the
  /// token's reuse window should close to zero.
  ///
  /// Returns true when a live token matching [value] and [operation]
  /// was found and removed; false otherwise (already consumed,
  /// expired, never issued, or operation mismatch). Callers may treat
  /// false as a security signal and refuse to launch privileged work.
  bool consumeToken(String value, String operation);

  /// Batch-prompt the user to allow-list [hosts] before any network
  /// traffic reaches them.
  Future<Map<String, bool>> requestHostApprovals(List<String> hosts);

  /// Returns true if [host] is already in the allow-list.
  Future<bool> isHostAllowed(String host);

  /// Persistently allow-list [host]. The UI calls this after the user
  /// confirms an "Allow this host?" prompt; subsequent
  /// [requireHostApproved] checks for the same host succeed without
  /// re-prompting. Idempotent.
  Future<void> approveHost(String host);

  /// Remove [host] from the allow-list. Surfaced in the Settings
  /// screen so users can revoke a previously-approved host.
  Future<void> revokeHost(String host);

  /// Enumerate every host currently on the allow-list. Used by the
  /// Settings screen to render the "Network allow-list" section so
  /// users can audit + revoke approvals after the fact.
  Future<List<String>> listApprovedHosts();

  /// Persist [fingerprint] for [host]. Called on first successful SSH
  /// connect once the user accepts the fingerprint.
  Future<void> pinHostFingerprint({
    required String host,
    required String fingerprint,
  });

  /// Returns the pinned fingerprint for [host], or null if none pinned.
  Future<String?> pinnedHostFingerprint(String host);

  /// Forget the pinned fingerprint for [host]. Lets the user revoke a
  /// trusted printer and force the next connect to re-prompt. Without
  /// this the only way to clear a fingerprint was deleting the secure
  /// storage by hand.
  Future<void> forgetHostFingerprint(String host);

  /// Enumerate every (host → fingerprint) pinned in the keystore.
  /// The Settings "Saved connections" panel renders this list so
  /// users can audit which printers Deckhand will silently trust on
  /// next launch.
  Future<Map<String, String>> listPinnedFingerprints();

  /// Returns the persisted GitHub Personal Access Token, or null if
  /// the user hasn't set one. Read by the upstream HTTP layer
  /// immediately before issuing a request to api.github.com to lift
  /// the unauthenticated rate-limit ceiling.
  Future<String?> getGitHubToken();

  /// Persist a GitHub PAT. Pass null/empty to clear. The token is
  /// kept in the platform secure store, never written to
  /// settings.json. Idempotent.
  Future<void> setGitHubToken(String? token);

  /// Stream of every outbound network request Deckhand makes during
  /// the session, after allow-list approval has passed. The S900
  /// progress screen subscribes to this and renders a "what just got
  /// fetched" panel beside the log so users can see, in real time,
  /// which hosts the install is reaching and how much data has
  /// flowed.
  ///
  /// Emitted exactly once per request (start) and once again on
  /// completion or failure (with `bytes` filled and `status` set).
  /// The UI groups consecutive emissions by [EgressEvent.requestId]
  /// to render a single row that updates in place.
  ///
  /// The stream is broadcast — multiple subscribers (the live panel,
  /// the debug-bundle capture buffer) can listen without buffering
  /// state on the producer side.
  Stream<EgressEvent> get egressEvents;

  /// Record an outbound request. Called by the dio interceptor in
  /// the production wiring; tests call directly with synthesized
  /// events.
  void recordEgress(EgressEvent event);
}

/// One-shot record of a network egress event. See
/// [SecurityService.egressEvents] for the producer contract and
/// [docs/ARCHITECTURE.md] (egress visualization) for the user-facing
/// panel that consumes it.
class EgressEvent {
  const EgressEvent({
    required this.requestId,
    required this.host,
    required this.url,
    required this.method,
    required this.operationLabel,
    required this.startedAt,
    this.bytes,
    this.status,
    this.completedAt,
    this.error,
  });

  /// Stable id for the request. Start and completion events share it
  /// so the UI can collapse them into one row.
  final String requestId;

  /// Lowercased hostname the request hit. Matches the allow-list
  /// representation used by [SecurityService.isHostAllowed].
  final String host;

  /// Full URL — surfaced in the panel's "details" expander only, so
  /// the per-row view stays one line.
  final String url;

  /// HTTP method (`GET`, `POST`, ...).
  final String method;

  /// Human-readable label tying this request to the install step
  /// that triggered it. Examples: "Profile fetch", "Klipper clone",
  /// "Mainsail download". The producer fills this from the active
  /// wizard step name; falls back to "Background" when no step is
  /// active.
  final String operationLabel;

  /// Time the request was issued.
  final DateTime startedAt;

  /// Bytes received. Filled on the completion event, null on start.
  final int? bytes;

  /// HTTP status code, or null on the start event / on connection
  /// failure (in which case [error] is non-null).
  final int? status;

  final DateTime? completedAt;

  /// Set on the completion event when the request errored before a
  /// response arrived (DNS, connection refused, TLS, timeout).
  final String? error;

  bool get isComplete => completedAt != null;
}

class ConfirmationToken {
  const ConfirmationToken({
    required this.value,
    required this.expiresAt,
    required this.operation,
  });
  final String value;
  final DateTime expiresAt;
  final String operation;
}

/// Thrown when a network-egress call is attempted to a host the user
/// has not approved. The UI is expected to catch this, show the
/// "Allow this host?" prompt, call `approveHost`, and retry.
///
/// We throw a typed exception (rather than silently dropping the
/// call or auto-approving) because the network-allowlist gate is the
/// single concrete user-visible surface of the trust model — making
/// it loud is the whole point.
class HostNotApprovedException implements Exception {
  const HostNotApprovedException({required this.host, required this.reason});
  final String host;
  final String reason;
  @override
  String toString() => 'HostNotApprovedException($host): $reason';
}

/// Helper that turns an arbitrary URL into a host suitable for
/// allowlist comparison. Strips the scheme, port, and path; lowercases.
/// Returns null when the URL is unparseable — callers treat that as
/// "deny" rather than letting an opaque value through.
String? hostFromUrl(String url) {
  try {
    final u = Uri.parse(url);
    final host = u.host.toLowerCase();
    return host.isEmpty ? null : host;
  } on FormatException {
    return null;
  }
}

/// Convenience wrapper around [SecurityService.isHostAllowed] that
/// throws when the host is not on the user's allowlist. Use this
/// from any code path that issues an outbound network call to a
/// non-printer host (GitHub, Armbian mirrors, OS image hosts).
Future<void> requireHostApproved(SecurityService security, String url) async {
  final host = hostFromUrl(url);
  if (host == null) {
    throw HostNotApprovedException(
      host: url,
      reason: 'URL did not parse to a host name',
    );
  }
  if (!await security.isHostAllowed(host)) {
    throw HostNotApprovedException(
      host: host,
      reason: 'host is not on the user-approved allowlist',
    );
  }
}
