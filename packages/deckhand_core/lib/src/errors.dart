/// Typed error hierarchy Deckhand throws from its services. The UI
/// catches DeckhandException at screen boundaries and renders friendly
/// messages + a "save debug bundle" action.
sealed class DeckhandException implements Exception {
  const DeckhandException(this.message, {this.cause, this.context});
  final String message;
  final Object? cause;
  final Map<String, Object?>? context;

  /// Short user-facing title (≤ ~40 chars). UIs render this as the
  /// headline on error cards.
  String get userTitle;

  /// Longer user-facing explanation + suggested action.
  String get userMessage => message;

  @override
  String toString() {
    final buf = StringBuffer('$runtimeType: $message');
    if (context != null && context!.isNotEmpty) buf.write(' context=$context');
    if (cause != null) buf.write('\n  caused by: $cause');
    return buf.toString();
  }
}

// -----------------------------------------------------------------
// Connection

class SshConnectionException extends DeckhandException {
  const SshConnectionException({
    required String host,
    required int port,
    Object? cause,
  }) : _host = host,
       _port = port,
       super('Could not connect to $host:$port', cause: cause);
  final String _host;
  final int _port;
  @override
  String get userTitle => 'Can\'t reach the printer';
  @override
  String get userMessage =>
      'Deckhand couldn\'t reach $_host on port $_port. Check the IP address, '
      'make sure the printer is powered on and on the same network, and try '
      'again.';
}

class SshAuthException extends DeckhandException {
  const SshAuthException({required String host, Object? cause})
    : _host = host,
      super('SSH authentication failed for $host', cause: cause);
  final String _host;
  @override
  String get userTitle => 'Couldn\'t sign in to the printer';
  @override
  String get userMessage =>
      'Deckhand tried the default SSH credentials declared by this profile '
      'but none of them worked for $_host. You can enter credentials manually '
      'on the connect screen.';
}

class HostKeyMismatchException extends DeckhandException {
  const HostKeyMismatchException({
    required String host,
    required String fingerprint,
  }) : _host = host,
       _fp = fingerprint,
       super('Host key mismatch for $host ($fingerprint)');
  final String _host;
  final String _fp;
  String get host => _host;
  String get fingerprint => _fp;
  @override
  String get userTitle => 'Printer\'s SSH fingerprint changed';
  @override
  String get userMessage =>
      'The fingerprint presented by $_host doesn\'t match the one Deckhand '
      'pinned previously ($_fp). This could mean the printer was reinstalled - '
      'or that something is intercepting the connection. Clear the pinned '
      'fingerprint in Settings if you expected this.';
}

/// Thrown on the first SSH connect to a host whose fingerprint Deckhand
/// has never seen. The UI should show the fingerprint to the user and
/// offer a "connect and pin" action that retries with `acceptHostKey:
/// true`.
class HostKeyUnpinnedException extends DeckhandException {
  const HostKeyUnpinnedException({
    required String host,
    required String fingerprint,
  }) : _host = host,
       _fp = fingerprint,
       super('Host key for $host is not yet pinned ($fingerprint)');
  final String _host;
  final String _fp;
  String get host => _host;
  String get fingerprint => _fp;
  @override
  String get userTitle => 'First time connecting to this printer';
  @override
  String get userMessage =>
      'Deckhand has not seen $_host before. Its SSH fingerprint is $_fp. '
      'Confirm that this matches the printer you expect, then accept to pin '
      'it for future connections.';
}

// -----------------------------------------------------------------
// Flash / disk

class FlashException extends DeckhandException {
  const FlashException(super.message, {super.cause, super.context});
  @override
  String get userTitle => 'Disk flash failed';
}

class DiskEnumerationException extends DeckhandException {
  const DiskEnumerationException(super.message, {super.cause});
  @override
  String get userTitle => 'Couldn\'t enumerate local disks';
}

class ElevationRequiredException extends DeckhandException {
  const ElevationRequiredException({required String op})
    : _op = op,
      super('Elevation required for operation "$op"');
  final String _op;
  @override
  String get userTitle => 'Administrator permission required';
  @override
  String get userMessage =>
      'The operation "$_op" requires administrator privileges. Deckhand will '
      'prompt you via your OS\'s elevation dialog when you confirm.';
}

// -----------------------------------------------------------------
// Profiles + upstreams

class ProfileFetchException extends DeckhandException {
  const ProfileFetchException(super.message, {super.cause});
  @override
  String get userTitle => 'Couldn\'t load printer profiles';
  @override
  String get userMessage =>
      'Deckhand couldn\'t fetch the printer profile registry. Check your '
      'internet connection, or try again once GitHub is reachable.';
}

class ProfileParseException extends DeckhandException {
  const ProfileParseException(super.message, {super.cause, super.context});
  @override
  String get userTitle => 'Malformed printer profile';
}

class UpstreamFetchException extends DeckhandException {
  const UpstreamFetchException(super.message, {super.cause});
  @override
  String get userTitle => 'Couldn\'t fetch an upstream component';
}

// -----------------------------------------------------------------
// Sidecar

class SidecarStartException extends DeckhandException {
  const SidecarStartException(super.message, {super.cause});
  @override
  String get userTitle => 'Helper binary didn\'t start';
  @override
  String get userMessage =>
      'Deckhand\'s background helper (deckhand-sidecar) didn\'t come up. Try '
      'reinstalling Deckhand; if the problem persists, open the app\'s log '
      'directory and save a debug bundle.';
}

class SidecarRpcException extends DeckhandException {
  const SidecarRpcException({
    required String method,
    required int code,
    required String reason,
  }) : _method = method,
       _code = code,
       super('Sidecar RPC $method failed (code $code): $reason');
  final String _method;
  final int _code;
  @override
  String get userTitle => 'Background operation failed';
  @override
  String get userMessage =>
      'The $_method operation returned an error from the helper (code $_code). '
      'Re-run the step, or save a debug bundle and file an issue.';
}
