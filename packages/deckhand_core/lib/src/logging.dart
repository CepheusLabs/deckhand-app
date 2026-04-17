import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Minimal structured logger for Deckhand.
///
/// Writes newline-delimited JSON to a rotating file in [logsDir], keeps
/// an in-memory ring buffer of the last N lines for the UI, and emits
/// every entry on [stream] so screens can render live tails.
class DeckhandLogger {
  DeckhandLogger({required this.logsDir, this.ringSize = 2000, this.sessionName});

  final String logsDir;
  final int ringSize;
  final String? sessionName;

  final _ring = <LogEntry>[];
  final _controller = StreamController<LogEntry>.broadcast();
  IOSink? _sink;

  Stream<LogEntry> get stream => _controller.stream;
  List<LogEntry> get ring => List.unmodifiable(_ring);

  /// Must be called before first [log] invocation.
  Future<void> init() async {
    final dir = Directory(logsDir);
    if (!await dir.exists()) await dir.create(recursive: true);

    final session = sessionName ?? _defaultSessionName();
    final f = File('$logsDir/$session.jsonl');
    _sink = f.openWrite(mode: FileMode.append, encoding: utf8);

    // Keep only the 10 most recent session logs.
    await _rotate();
  }

  void log(String message, {LogLevel level = LogLevel.info, Map<String, Object?>? data}) {
    final entry = LogEntry(
      timestamp: DateTime.now().toUtc(),
      level: level,
      message: message,
      data: data,
    );
    _ring.add(entry);
    if (_ring.length > ringSize) {
      _ring.removeAt(0);
    }
    _controller.add(entry);
    final line = jsonEncode(entry.toJson());
    _sink?.writeln(line);
  }

  void debug(String m, {Map<String, Object?>? data}) =>
      log(m, level: LogLevel.debug, data: data);
  void info(String m, {Map<String, Object?>? data}) =>
      log(m, level: LogLevel.info, data: data);
  void warn(String m, {Map<String, Object?>? data}) =>
      log(m, level: LogLevel.warn, data: data);
  void error(String m, {Map<String, Object?>? data}) =>
      log(m, level: LogLevel.error, data: data);

  /// Collect everything in [logsDir] into a tar-style bundle the UI can
  /// ship off to support. Returns the local path.
  Future<String> saveDebugBundle(String destDir) async {
    await Directory(destDir).create(recursive: true);
    final ts = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    final tarPath = '$destDir/deckhand-debug-$ts.tar';
    final result = await Process.run(
      'tar',
      ['-cf', tarPath, '-C', logsDir, '.'],
    );
    if (result.exitCode != 0) {
      throw Exception('debug bundle tar failed: ${result.stderr}');
    }
    return tarPath;
  }

  Future<void> close() async {
    await _sink?.flush();
    await _sink?.close();
    await _controller.close();
  }

  String _defaultSessionName() {
    final now = DateTime.now().toUtc();
    return 'session-'
        '${now.year}${_two(now.month)}${_two(now.day)}-'
        '${_two(now.hour)}${_two(now.minute)}${_two(now.second)}';
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  Future<void> _rotate() async {
    final dir = Directory(logsDir);
    if (!await dir.exists()) return;
    final files = (await dir.list().toList())
        .whereType<File>()
        .where((f) => f.path.endsWith('.jsonl'))
        .toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    for (final old in files.skip(10)) {
      try {
        await old.delete();
      } catch (_) {}
    }
  }
}

enum LogLevel { debug, info, warn, error }

class LogEntry {
  const LogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
    this.data,
  });

  final DateTime timestamp;
  final LogLevel level;
  final String message;
  final Map<String, Object?>? data;

  Map<String, Object?> toJson() => {
        't': timestamp.toIso8601String(),
        'l': level.name,
        'm': message,
        if (data != null) 'd': data,
      };
}
