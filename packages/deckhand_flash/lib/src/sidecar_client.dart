import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

/// Common surface adapters call into. Implemented by both the
/// concrete [SidecarClient] (single connection) and
/// [SidecarSupervisor] (auto-restart wrapper). Adapters take this
/// type so they can be wired against either at the binding site
/// without code change.
abstract class SidecarConnection {
  Future<Map<String, dynamic>> call(String method, Map<String, dynamic> params);
  Stream<SidecarEvent> callStreaming(
    String method,
    Map<String, dynamic> params,
  );
  Stream<SidecarNotification> subscribeToOperation(String operationId);
  Stream<SidecarNotification> get notifications;
  Future<void> shutdown();
}

/// JSON-RPC 2.0 client that spawns the Go sidecar binary and talks to it
/// over newline-delimited stdin/stdout.
///
/// Supports:
///   - request/response with id correlation
///   - notifications (sidecar -> UI) delivered via [notifications]
///   - per-operation notification streams via [subscribeToOperation]
///   - error responses surfaced as [SidecarError] exceptions
class SidecarClient implements SidecarConnection {
  SidecarClient({required this.binaryPath, DeckhandLogger? logger})
    : _logger = logger;

  final String binaryPath;

  /// When non-null, sidecar stderr is routed through [_logger.warn];
  /// otherwise we fall back to [stderr.writeln] so the line still
  /// lands somewhere auditable instead of disappearing into print().
  final DeckhandLogger? _logger;

  final _uuid = const Uuid();
  Process? _process;
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  final _notificationsController =
      StreamController<SidecarNotification>.broadcast();
  final _operationSubscribers =
      <String, StreamController<SidecarNotification>>{};
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  bool _started = false;
  void Function(String line)? _writeLineOverride;
  Future<void> Function()? _flushOverride;

  /// All notifications from the sidecar. Each one carries an
  /// `operation_id` that correlates it to the request that spawned it.
  @override
  Stream<SidecarNotification> get notifications =>
      _notificationsController.stream;

  /// Start the sidecar process. Call once before making any calls.
  Future<void> start() async {
    if (_started) return;
    _started = true;

    try {
      _process = await Process.start(
        binaryPath,
        const [],
        mode: ProcessStartMode.normal,
        runInShell: false,
      );

      _stdoutSub = _process!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            _handleLine,
            onError: (Object e, StackTrace st) {
              _failAll(e.toString());
            },
            onDone: _onProcessDone,
          );

      // stderr -> route through DeckhandLogger so bug reports and
      // crash dumps can capture sidecar diagnostics without those
      // lines leaking to stdout (which would interfere with an
      // app-launched-from-terminal case) or to print() (flagged by
      // avoid_print).
      _stderrSub = _process!.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            final logger = _logger;
            if (logger != null) {
              logger.warn('[sidecar] $line');
            } else {
              // Use stderr (not print/stdout) so the line does not
              // interfere with JSON-RPC framing on stdout and stays
              // out of user-visible UI surfaces.
              stderr.writeln('[sidecar] $line');
            }
          });

      // Smoke test that the process responded. Timeout after 5s.
      await call('ping', const {}).timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          throw const SidecarError(
            code: -1,
            message: 'Sidecar did not respond to ping within 5s',
          );
        },
      );
    } on Object catch (e, st) {
      await _resetProcessState();
      _logger?.warn('sidecar startup failed: $e\n$st');
      rethrow;
    }
  }

  /// Make a JSON-RPC call and await the response.
  @override
  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params,
  ) async {
    if (!_started) {
      throw StateError('SidecarClient not started');
    }
    final id = _uuid.v4();
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    final msg = jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    try {
      _writeLine(msg);
      await _flush();
    } on Object catch (e, st) {
      _pending.remove(id);
      if (!completer.isCompleted) {
        completer.completeError(e, st);
      }
    }
    return completer.future;
  }

  /// Subscribe to progress notifications for a specific operation. The
  /// returned stream closes when the matching request completes.
  ///
  /// The StreamController escapes into [_operationSubscribers] and is
  /// closed by `callStreaming`'s completer callbacks (on success or
  /// error) and by `shutdown()`. The analyzer's close_sinks check
  /// can't trace that ownership chain.
  @override
  Stream<SidecarNotification> subscribeToOperation(String operationId) {
    // ignore: close_sinks
    final c = _operationSubscribers.putIfAbsent(
      operationId,
      () => StreamController<SidecarNotification>.broadcast(),
    );
    return c.stream;
  }

  /// Convenience: issue a call whose progress updates you want to stream
  /// as [SidecarNotification]s along with the final response.
  ///
  /// Returns a stream that emits notifications then completes with a
  /// single [SidecarResult] event (or errors with [SidecarError]).
  @override
  Stream<SidecarEvent> callStreaming(
    String method,
    Map<String, dynamic> params,
  ) {
    if (!_started) {
      throw StateError('SidecarClient not started');
    }
    final id = _uuid.v4();
    final controller = StreamController<SidecarEvent>();
    final opSub = _operationSubscribers.putIfAbsent(
      id,
      () => StreamController<SidecarNotification>.broadcast(),
    );
    late StreamSubscription<SidecarNotification> opForwardSub;
    var released = false;
    Future<void> releaseOperation() async {
      if (released) return;
      released = true;
      _pending.remove(id);
      _operationSubscribers.remove(id);
      await opForwardSub.cancel();
      if (!opSub.isClosed) {
        await opSub.close();
      }
    }

    opForwardSub = opSub.stream.listen((n) {
      if (!controller.isClosed) {
        controller.add(SidecarProgress(n));
      }
    });

    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    final msg = jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    unawaited(_sendStreamingRequest(msg, completer));

    completer.future
        .then((res) async {
          if (!controller.isClosed) {
            controller.add(SidecarResult(res));
            await controller.close();
          }
          await releaseOperation();
        })
        .catchError((Object e, StackTrace st) async {
          if (!controller.isClosed) {
            controller.addError(e, st);
            await controller.close();
          }
          await releaseOperation();
        });
    controller.onCancel = () async {
      final shouldCancel = _pending.containsKey(id);
      await releaseOperation();
      if (shouldCancel) {
        await _sendCancelRequest(id);
      }
    };
    return controller.stream;
  }

  Future<void> _sendStreamingRequest(
    String msg,
    Completer<Map<String, dynamic>> completer,
  ) async {
    try {
      _writeLine(msg);
      await _flush();
    } on Object catch (e, st) {
      if (!completer.isCompleted) {
        completer.completeError(e, st);
      }
    }
  }

  Future<void> _sendCancelRequest(String operationId) async {
    final msg = jsonEncode({
      'jsonrpc': '2.0',
      'id': '${operationId}_cancel',
      'method': 'jobs.cancel',
      'params': {'id': operationId},
    });
    try {
      _writeLine(msg);
      await _flush();
    } on Object catch (e, st) {
      _logger?.warn('sidecar jobs.cancel write failed: $e\n$st');
    }
  }

  /// Cleanly shut the sidecar down. Best-effort: if the graceful
  /// `shutdown` RPC times out we kill the process; if `kill()` itself
  /// fails (rare — process already gone, OS refused) the failure goes
  /// to the attached logger so a misbehaving sidecar leaves a trail
  /// instead of disappearing silently.
  @override
  Future<void> shutdown() async {
    final process = _process;
    if (process != null) {
      try {
        await call('shutdown', const {}).timeout(const Duration(seconds: 2));
      } on TimeoutException catch (e) {
        _logger?.warn('sidecar shutdown RPC timed out: $e');
      } on SidecarError catch (e) {
        _logger?.warn('sidecar shutdown RPC errored: $e');
      } catch (e, st) {
        _logger?.warn('sidecar shutdown RPC failed: $e\n$st');
      }
    }
    _failAll('sidecar shutdown');
    try {
      process?.kill();
    } on Object catch (e, st) {
      _logger?.warn('sidecar kill() failed: $e\n$st');
    }
    await _stdoutSub?.cancel();
    _stdoutSub = null;
    await _stderrSub?.cancel();
    _stderrSub = null;
    if (!_notificationsController.isClosed) {
      await _notificationsController.close();
    }
    for (final c in _operationSubscribers.values) {
      await c.close();
    }
    _operationSubscribers.clear();
    _process = null;
    _started = false;
    _writeLineOverride = null;
    _flushOverride = null;
  }

  Future<void> _resetProcessState() async {
    _failAll('sidecar startup failed');
    try {
      _process?.kill();
    } on Object catch (e, st) {
      _logger?.warn('sidecar kill() after startup failure failed: $e\n$st');
    }
    await _stdoutSub?.cancel();
    _stdoutSub = null;
    await _stderrSub?.cancel();
    _stderrSub = null;
    for (final c in _operationSubscribers.values) {
      await c.close();
    }
    _operationSubscribers.clear();
    _process = null;
    _started = false;
    _writeLineOverride = null;
    _flushOverride = null;
  }

  // -----------------------------------------------------------------

  /// Feed a single newline-delimited JSON line into the client's
  /// response router as if it had arrived from the sidecar's stdout.
  /// Used by unit tests to exercise framing, correlation, and error
  /// mapping without spawning a real process.
  @visibleForTesting
  void handleLineForTesting(String line) => _handleLine(line);

  /// Register a completer for a request id so a test can correlate the
  /// response it later feeds via [handleLineForTesting] without having
  /// written to stdin. Returns the id the test should reference.
  @visibleForTesting
  String registerPendingForTesting(
    String id,
    Completer<Map<String, dynamic>> completer,
  ) {
    _pending[id] = completer;
    return id;
  }

  @visibleForTesting
  void startForTesting({
    required void Function(String line) writeLine,
    required Future<void> Function() flush,
  }) {
    _started = true;
    _writeLineOverride = writeLine;
    _flushOverride = flush;
  }

  @visibleForTesting
  int get pendingRequestCountForTesting => _pending.length;

  @visibleForTesting
  int get operationSubscriberCountForTesting => _operationSubscribers.length;

  void _writeLine(String line) {
    final override = _writeLineOverride;
    if (override != null) {
      override(line);
      return;
    }
    final process = _process;
    if (process == null) {
      throw StateError('SidecarClient not started');
    }
    process.stdin.writeln(line);
  }

  Future<void> _flush() {
    final override = _flushOverride;
    if (override != null) {
      return override();
    }
    final process = _process;
    if (process == null) {
      throw StateError('SidecarClient not started');
    }
    return process.stdin.flush();
  }

  void _handleLine(String line) {
    if (line.trim().isEmpty) return;
    final obj = _decodeJsonObject(line);
    if (obj == null) return; // malformed line, ignore

    // Notification (no id)
    if (!obj.containsKey('id')) {
      final params = _jsonMap(obj['params']) ?? const <String, dynamic>{};
      final opId = _jsonString(params['operation_id']);
      final note = SidecarNotification(
        method: _jsonString(obj['method']) ?? '',
        params: params,
        operationId: opId,
      );
      _notificationsController.add(note);
      if (opId != null) {
        _operationSubscribers[opId]?.add(note);
      }
      return;
    }

    // Response with id
    final id = obj['id'].toString();
    final completer = _pending.remove(id);
    if (completer == null) return;

    if (obj.containsKey('error')) {
      // A compromised or buggy sidecar could send an error object
      // without a `code`, or with one that isn't a number. Previously
      // this crashed the app with an unhandled TypeError at the ^. Map
      // malformed shapes to a synthetic -1 so the call still completes
      // with a readable message instead of crashing the isolate.
      final errRaw = obj['error'];
      if (errRaw is! Map) {
        completer.completeError(
          const SidecarError(
            code: -1,
            message: 'sidecar returned malformed error envelope',
          ),
        );
        return;
      }
      final err = _stringKeyMap(errRaw);
      final rawCode = err['code'];
      final code = rawCode is num ? rawCode.toInt() : -1;
      completer.completeError(
        SidecarError(
          code: code,
          message: _jsonString(err['message']) ?? '',
          data: err['data'],
        ),
      );
    } else {
      final result = obj['result'];
      completer.complete(_jsonMap(result) ?? {'value': result});
    }
  }

  void _onProcessDone() {
    _failAll('sidecar process exited');
  }

  void _failAll(String msg) {
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(SidecarError(code: -1, message: msg));
      }
    }
    _pending.clear();
  }
}

Map<String, dynamic>? _decodeJsonObject(String line) {
  try {
    final decoded = jsonDecode(line);
    return _jsonMap(decoded);
  } catch (_) {
    return null;
  }
}

Map<String, dynamic>? _jsonMap(Object? value) =>
    value is Map ? _stringKeyMap(value) : null;

Map<String, dynamic> _stringKeyMap(Map value) {
  final out = <String, dynamic>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is String) out[key] = entry.value;
  }
  return out;
}

String? _jsonString(Object? value) => value is String ? value : null;

/// A notification emitted by the sidecar (no response expected).
class SidecarNotification {
  const SidecarNotification({
    required this.method,
    required this.params,
    this.operationId,
  });
  final String method;
  final Map<String, dynamic> params;
  final String? operationId;
}

/// Error shape for failed JSON-RPC calls.
class SidecarError implements Exception {
  const SidecarError({required this.code, required this.message, this.data});
  final int code;
  final String message;
  final Object? data;

  @override
  String toString() => 'SidecarError($code): $message';
}

/// Event kinds emitted by [SidecarClient.callStreaming].
sealed class SidecarEvent {
  const SidecarEvent();
}

class SidecarProgress extends SidecarEvent {
  const SidecarProgress(this.notification);
  final SidecarNotification notification;
}

class SidecarResult extends SidecarEvent {
  const SidecarResult(this.result);
  final Map<String, dynamic> result;
}
