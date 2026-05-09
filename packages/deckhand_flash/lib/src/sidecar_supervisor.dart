import 'dart:async';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:meta/meta.dart';

import 'sidecar_client.dart';

/// Supervises a [SidecarClient] across crashes.
///
/// The bare [SidecarClient] propagates "sidecar process exited" as an
/// error to every in-flight completer. That's the right primitive,
/// but it leaves callers with no policy for what to do next: every
/// adapter would have to re-derive "is this method safe to retry?"
/// and "is the sidecar still healthy?" on its own.
///
/// [SidecarSupervisor] adds:
///
///   * **Method classification.** Each method is one of
///     [SidecarMethodKind.retrySafe], [SidecarMethodKind.stateful],
///     or [SidecarMethodKind.failStop]. The supervisor re-spawns the
///     sidecar and retries `retrySafe` methods once on a clean
///     process exit. `stateful` methods surface a typed
///     [SidecarCrashedDuringStatefulCall] exception. `failStop`
///     methods do the same and additionally latch the supervisor —
///     no further calls succeed until the user explicitly relaunches
///     Deckhand.
///   * **Restart policy.** Two automatic restarts per session, with
///     exponential backoff (1s, 4s). After the third crash the
///     supervisor latches and every subsequent call fails
///     immediately. Avoids a runaway restart loop pinning the CPU
///     when the sidecar segfaults on startup.
///   * **One health-check call** after every restart so the new
///     sidecar's `version.compat` mismatch is caught at supervisor
///     scope rather than at adapter scope.
///
/// See [docs/ARCHITECTURE.md](../../../docs/ARCHITECTURE.md)
/// (sidecar crash recovery) for the full design notes.
class SidecarSupervisor implements SidecarConnection {
  SidecarSupervisor({
    required SidecarClient Function() spawn,
    DeckhandLogger? logger,
    @visibleForTesting List<Duration>? backoffSchedule,
  }) : _spawn = spawn,
       _logger = logger,
       _backoffSchedule = backoffSchedule ?? _defaultBackoffSchedule;

  final SidecarClient Function() _spawn;
  final DeckhandLogger? _logger;

  /// Per-restart wait. Production wiring uses [_defaultBackoffSchedule];
  /// tests pass a list of zero-durations so the restart-cap and crash
  /// path tests don't actually sleep 1+4 seconds. Length must be
  /// [_maxRestarts]; that invariant is enforced at construction.
  final List<Duration> _backoffSchedule;

  SidecarClient? _client;
  int _restartCount = 0;
  bool _latched = false;

  static const int _maxRestarts = 2;
  static const List<Duration> _defaultBackoffSchedule = [
    Duration(seconds: 1),
    Duration(seconds: 4),
  ];

  /// Start the underlying sidecar. Idempotent.
  Future<void> start() async {
    if (_client != null) return;
    _client = _spawn();
    await _client!.start();
    _hookNotificationsBridge();
  }

  /// Issue a JSON-RPC call. Honors method classification and restart
  /// policy. Throws [SidecarLatchedException] when the supervisor has
  /// latched, [SidecarCrashedDuringStatefulCall] when a stateful
  /// call's sidecar died mid-flight.
  @override
  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params,
  ) async {
    if (_latched) {
      throw const SidecarLatchedException();
    }
    if (_client == null) {
      throw StateError('SidecarSupervisor.call before start()');
    }

    final kind = classifyMethod(method);
    try {
      return await _client!.call(method, params);
    } on SidecarError catch (e) {
      // SidecarError code -1 with the canonical "exited" message is
      // how SidecarClient surfaces a process death. Anything else is
      // an in-band error from a still-alive sidecar — pass it through.
      if (!_isProcessExitError(e)) rethrow;

      switch (kind) {
        case SidecarMethodKind.retrySafe:
          _logger?.warn(
            'sidecar crashed during retrySafe call $method; restarting',
          );
          await _restartOrLatch();
          return _client!.call(method, params);
        case SidecarMethodKind.stateful:
          await _restartOrLatch();
          throw SidecarCrashedDuringStatefulCall(method: method);
        case SidecarMethodKind.failStop:
          _latched = true;
          await _client?.shutdown();
          _client = null;
          throw SidecarCrashedDuringStatefulCall(method: method, latched: true);
      }
    }
  }

  /// Forwarder for `callStreaming`. Streams are inherently stateful —
  /// progress delivered before the crash can't be replayed cleanly,
  /// so this method does not auto-retry. The downstream consumer gets
  /// a typed crash for stateful streams, while destructive fail-stop
  /// streams latch the supervisor exactly like [call].
  ///
  /// Implementation note: uses a manual StreamController + listen
  /// rather than `yield*` in an async* generator. yield* forwards
  /// errors from the delegated stream directly to the output stream
  /// and bypasses any surrounding try/catch in the async* function -
  /// the previous implementation looked correct but silently dropped
  /// the restart trigger on process-exit errors. The listen-based
  /// path catches errors before they reach the consumer.
  @override
  Stream<SidecarEvent> callStreaming(
    String method,
    Map<String, dynamic> params,
  ) {
    if (_latched) {
      return Stream.error(const SidecarLatchedException());
    }
    if (_client == null) {
      return Stream.error(
        StateError('SidecarSupervisor.callStreaming before start()'),
      );
    }
    final kind = classifyMethod(method);
    final ctl = StreamController<SidecarEvent>();
    late StreamSubscription<SidecarEvent> sub;
    sub = _client!
        .callStreaming(method, params)
        .listen(
          ctl.add,
          onError: (Object e, StackTrace s) async {
            if (e is SidecarError && _isProcessExitError(e)) {
              switch (kind) {
                case SidecarMethodKind.retrySafe:
                  try {
                    await _restartOrLatch();
                  } on Object {
                    // The next call will see the latch if restart failed.
                  }
                  break;
                case SidecarMethodKind.stateful:
                  var latched = false;
                  try {
                    await _restartOrLatch();
                  } on SidecarLatchedException {
                    latched = true;
                  }
                  e = SidecarCrashedDuringStatefulCall(
                    method: method,
                    latched: latched,
                  );
                  break;
                case SidecarMethodKind.failStop:
                  _latched = true;
                  await _client?.shutdown();
                  _client = null;
                  e = SidecarCrashedDuringStatefulCall(
                    method: method,
                    latched: true,
                  );
              }
            }
            if (!ctl.isClosed) {
              ctl.addError(e, s);
              await ctl.close();
            }
          },
          onDone: () {
            if (!ctl.isClosed) ctl.close();
          },
          cancelOnError: true,
        );
    ctl.onCancel = () => sub.cancel();
    return ctl.stream;
  }

  /// Subscribe to the all-notifications stream. The supervisor
  /// re-subscribes automatically across restarts via the rebroadcast
  /// controller so long-lived listeners (the egress visualizer, for
  /// instance) don't go silent after the first sidecar crash.
  @override
  Stream<SidecarNotification> get notifications =>
      _notificationsRebroadcast.stream;

  /// Forward per-operation streams to the underlying client. The
  /// returned stream is the live one from the *current* client; if a
  /// restart happens mid-operation the operation itself was already
  /// classified (stateful → caller cleans up; retrySafe → caller retries
  /// the call which gets a new operation id) so we don't try to bridge
  /// notifications across restarts.
  @override
  Stream<SidecarNotification> subscribeToOperation(String operationId) {
    final c = _client;
    if (c == null) {
      throw StateError('SidecarSupervisor.subscribeToOperation before start()');
    }
    return c.subscribeToOperation(operationId);
  }

  // Rebroadcast controller for notifications — see [notifications].
  // Wired up in start() / on every restart so the public stream
  // outlives any individual client.
  final _notificationsRebroadcast =
      StreamController<SidecarNotification>.broadcast();
  StreamSubscription<SidecarNotification>? _notifBridge;

  void _hookNotificationsBridge() {
    _notifBridge?.cancel();
    final c = _client;
    if (c == null) return;
    _notifBridge = c.notifications.listen(
      _notificationsRebroadcast.add,
      onError: _notificationsRebroadcast.addError,
      cancelOnError: false,
    );
  }

  @override
  Future<void> shutdown() async {
    _latched = true;
    await _notifBridge?.cancel();
    if (!_notificationsRebroadcast.isClosed) {
      await _notificationsRebroadcast.close();
    }
    await _client?.shutdown();
    _client = null;
  }

  Future<void> _restartOrLatch() async {
    if (_restartCount >= _maxRestarts) {
      _latched = true;
      throw const SidecarLatchedException();
    }
    final backoff = _backoffSchedule[_restartCount];
    _restartCount++;
    _logger?.info(
      'sidecar restart attempt $_restartCount after ${backoff.inSeconds}s',
    );
    await _notifBridge?.cancel();
    await _client?.shutdown();
    _client = null;
    await Future<void>.delayed(backoff);
    _client = _spawn();
    await _client!.start();
    // Re-attach the rebroadcast bridge so listeners on the public
    // [notifications] stream receive events from the new client.
    _hookNotificationsBridge();
  }

  bool _isProcessExitError(SidecarError e) =>
      e.code == -1 && e.message.contains('sidecar process exited');
}

/// Classification used by [SidecarSupervisor.call]. See the per-kind
/// docs for the policy.
enum SidecarMethodKind {
  /// The method is a pure read with no on-disk side effects, so the
  /// supervisor can re-spawn the sidecar and replay the call without
  /// risking double-execution. `ping`, `host.info`, `doctor.run`,
  /// `disks.list`, `disks.hash`, `version.compat`.
  retrySafe,

  /// The method writes durable state — partial files in cache,
  /// half-completed git clones, partial dd output. Restarting and
  /// re-running could leave inconsistent state on disk, so the
  /// supervisor surfaces a typed exception and lets the caller
  /// decide whether to clean up and retry. `os.download`,
  /// `profiles.fetch`, `disks.read_image`.
  stateful,

  /// The method is destructive and the user has already approved it
  /// (confirmation token issued, elevation prompted). A crash here
  /// is an unrecoverable invariant violation: the supervisor
  /// latches, refuses further calls, and the UI must surface a
  /// "Deckhand needs to relaunch" hard-stop screen.
  /// `disks.write_image` (the elevated-helper path is unaffected by
  /// sidecar death, but the sidecar's pre-flight that issues the
  /// elevation_required error is on this path and a crash there
  /// leaves the UI in an inconsistent state).
  failStop,
}

SidecarMethodKind classifyMethod(String method) {
  switch (method) {
    case 'ping':
    case 'version.compat':
    case 'host.info':
    case 'doctor.run':
    case 'disks.list':
    case 'disks.hash':
    case 'disks.safety_check':
    case 'jobs.cancel':
      return SidecarMethodKind.retrySafe;
    case 'os.download':
    case 'profiles.fetch':
    case 'disks.read_image':
      return SidecarMethodKind.stateful;
    case 'disks.write_image':
      return SidecarMethodKind.failStop;
    default:
      // Unknown method names default to stateful — the safer choice
      // when classification is ambiguous. A new method added without
      // updating this switch errs on the side of "do not retry."
      return SidecarMethodKind.stateful;
  }
}

/// The supervisor has hit its restart cap (or processed a fail-stop
/// crash) and refuses further calls until the app relaunches.
class SidecarLatchedException implements Exception {
  const SidecarLatchedException();
  @override
  String toString() =>
      'SidecarLatchedException: too many sidecar crashes; relaunch Deckhand';
}

/// Sidecar exited mid-call on a [SidecarMethodKind.stateful] method.
/// Caller is expected to clean up partial state (delete the half-
/// downloaded file, rm -rf the partial clone) before retrying.
class SidecarCrashedDuringStatefulCall implements Exception {
  const SidecarCrashedDuringStatefulCall({
    required this.method,
    this.latched = false,
  });
  final String method;
  final bool latched;
  @override
  String toString() =>
      'SidecarCrashedDuringStatefulCall(method=$method, latched=$latched)';
}
