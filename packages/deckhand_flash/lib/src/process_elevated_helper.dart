import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:path/path.dart' as p;

/// [ElevatedHelperService] that launches the sibling
/// `deckhand-elevated-helper` binary with platform-native elevation.
///
/// Why a separate process: the Go sidecar runs as the user and must not
/// have admin/root. Raw block-device writes need elevation, so the
/// helper is one-shot, exits when the write completes, and has no
/// network access.
///
/// Elevation per platform:
///   - Windows: `powershell.exe Start-Process -Verb RunAs -Wait` with
///     stdout redirected to a tempfile; UI tails that file for JSON
///     progress events.
///   - macOS: `osascript -e 'do shell script ... with administrator
///     privileges'` - triggers the Authorization Services dialog.
///   - Linux: `pkexec` - the helper inherits stdio directly so
///     progress streams live on stdout.
class ProcessElevatedHelperService implements ElevatedHelperService {
  ProcessElevatedHelperService({required this.helperPath});

  /// Absolute path to the `deckhand-elevated-helper` binary.
  final String helperPath;

  @override
  Stream<FlashProgress> writeImage({
    required String imagePath,
    required String diskId,
    required String confirmationToken,
    bool verifyAfterWrite = true,
    String? expectedSha256,
  }) async* {
    final args = <String>[
      'write-image',
      '--image', imagePath,
      '--target', diskId,
      '--token', confirmationToken,
      '--verify', verifyAfterWrite.toString(),
      if (expectedSha256 != null) ...['--sha256', expectedSha256],
    ];

    if (Platform.isWindows) {
      yield* _runWindows(args);
    } else if (Platform.isMacOS) {
      yield* _runMacOs(args);
    } else {
      yield* _runLinux(args);
    }
  }

  // -----------------------------------------------------------------
  // Windows: PowerShell Start-Process -Verb RunAs. Helper output is
  // redirected to a tempfile; we tail it for JSON progress events.

  Stream<FlashProgress> _runWindows(List<String> helperArgs) async* {
    final stdoutFile = File(
      p.join(
        Directory.systemTemp.path,
        'deckhand-helper-${DateTime.now().millisecondsSinceEpoch}.log',
      ),
    );
    final stderrFile = File('${stdoutFile.path}.err');
    await stdoutFile.writeAsString('');

    final argList = helperArgs.map(powerShellQuoteArg).join(',');

    final psCommand = [
      '\$p = Start-Process -FilePath "$helperPath" ',
      '-ArgumentList $argList ',
      '-Verb RunAs -Wait -PassThru ',
      '-RedirectStandardOutput "${stdoutFile.path}" ',
      '-RedirectStandardError "${stderrFile.path}";',
      'exit \$p.ExitCode',
    ].join();

    final completer = Completer<int>();
    final ps = await Process.start('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      psCommand,
    ], runInShell: false);

    ps.exitCode.then(completer.complete);

    // Tail the redirected stdout until the process exits. We poll at a
    // modest rate because the helper emits at ~4Hz and the file I/O is
    // cheap.
    var offset = 0;
    final carry = StringBuffer();

    try {
      while (!completer.isCompleted) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final len = await stdoutFile.length();
        if (len > offset) {
          final raf = await stdoutFile.open();
          await raf.setPosition(offset);
          final bytes = await raf.read(len - offset);
          await raf.close();
          offset = len;
          final chunk = utf8.decode(bytes, allowMalformed: true);
          carry.write(chunk);
          var s = carry.toString();
          var nl = s.indexOf('\n');
          while (nl >= 0) {
            final line = s.substring(0, nl).trimRight();
            s = s.substring(nl + 1);
            final ev = _parseHelperLine(line);
            if (ev != null) yield ev;
            nl = s.indexOf('\n');
          }
          carry
            ..clear()
            ..write(s);
        }
      }
      // Drain remainder.
      final remainder = await stdoutFile.readAsString();
      if (remainder.length > offset) {
        final tail = remainder.substring(offset);
        for (final line in const LineSplitter().convert(tail)) {
          final ev = _parseHelperLine(line);
          if (ev != null) yield ev;
        }
      }

      final exit = await completer.future;
      if (exit != 0) {
        // Surface any captured stderr in the exception message so the
        // user isn't staring at a bare exit code.
        String? errTail;
        try {
          if (await stderrFile.exists()) {
            errTail = (await stderrFile.readAsString()).trim();
            if (errTail.length > 512) {
              errTail = errTail.substring(errTail.length - 512);
            }
          }
        } catch (_) {}
        throw ElevatedHelperException(
          'elevated helper exited with code $exit'
          '${errTail == null || errTail.isEmpty ? "" : "\n$errTail"}',
        );
      }
    } finally {
      // Best-effort cleanup. We don't surface errors here: the log
      // files are in %TEMP% and Windows will reap them on its own
      // schedule anyway.
      for (final f in [stdoutFile, stderrFile]) {
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
  }

  // -----------------------------------------------------------------
  // macOS: osascript with administrator privileges. Helper stdout is
  // captured line-by-line.

  Stream<FlashProgress> _runMacOs(List<String> helperArgs) async* {
    final shell = StringBuffer(_shellQuote(helperPath));
    for (final a in helperArgs) {
      shell
        ..write(' ')
        ..write(_shellQuote(a));
    }
    final script =
        'do shell script "${shell.toString().replaceAll('"', r'\"')}" '
        'with administrator privileges';

    final proc = await Process.start('osascript', ['-e', script]);
    yield* _streamLines(proc);
  }

  // -----------------------------------------------------------------
  // Linux: pkexec. Helper stdio is inherited so we just parse stdout.

  Stream<FlashProgress> _runLinux(List<String> helperArgs) async* {
    final proc = await Process.start('pkexec', [helperPath, ...helperArgs]);
    yield* _streamLines(proc);
  }

  Stream<FlashProgress> _streamLines(Process proc) async* {
    final events = StreamController<FlashProgress>();
    late StreamSubscription<String> sub;
    sub = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            final ev = _parseHelperLine(line);
            if (ev != null) events.add(ev);
          },
          onError: events.addError,
          onDone: () async {
            final code = await proc.exitCode;
            if (code != 0) {
              events.addError(
                ElevatedHelperException(
                  'elevated helper exited with code $code',
                ),
              );
            }
            await events.close();
          },
        );
    try {
      yield* events.stream;
    } finally {
      await sub.cancel();
    }
  }
}

FlashProgress? _parseHelperLine(String line) {
  if (line.trim().isEmpty) return null;
  Map<String, dynamic> obj;
  try {
    obj = jsonDecode(line) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
  final event = obj['event'] as String?;
  switch (event) {
    case 'preparing':
      return FlashProgress(
        bytesDone: 0,
        bytesTotal: 0,
        phase: FlashPhase.preparing,
        message: obj['device'] as String?,
      );
    case 'progress':
      final done = (obj['bytes_done'] as num?)?.toInt() ?? 0;
      final total = (obj['bytes_total'] as num?)?.toInt() ?? 0;
      final phase = _phaseFromString(obj['phase'] as String?);
      return FlashProgress(
        bytesDone: done,
        bytesTotal: total,
        phase: phase,
        message: obj['sha256'] as String?,
      );
    case 'done':
      final done = (obj['bytes'] as num?)?.toInt() ?? 0;
      return FlashProgress(
        bytesDone: done,
        bytesTotal: done,
        phase: FlashPhase.done,
        message: obj['sha256'] as String?,
      );
    case 'error':
      return FlashProgress(
        bytesDone: 0,
        bytesTotal: 0,
        phase: FlashPhase.failed,
        message: obj['message'] as String?,
      );
    default:
      return null;
  }
}

FlashPhase _phaseFromString(String? s) => switch (s) {
  'writing' => FlashPhase.writing,
  'verifying' || 'write-complete' || 'verified' => FlashPhase.verifying,
  'done' => FlashPhase.done,
  'failed' => FlashPhase.failed,
  _ => FlashPhase.preparing,
};

String _shellQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// Quote [arg] for inclusion in a PowerShell `-ArgumentList a,b,c`
/// literal. Double-wraps + doubles any embedded `"` per PowerShell's
/// native escaping rules. No shell expansion happens because we pass
/// the args as an array, not a single string.
///
/// Public so the unit test can pin the semantics down - a bad escape
/// could silently misquote a disk path with a space and flash the
/// wrong device.
String powerShellQuoteArg(String arg) => '"${arg.replaceAll('"', '""')}"';

class ElevatedHelperException implements Exception {
  ElevatedHelperException(this.message);
  final String message;
  @override
  String toString() => 'ElevatedHelperException: $message';
}
