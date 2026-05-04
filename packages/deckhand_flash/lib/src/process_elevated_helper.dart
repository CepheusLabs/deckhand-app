import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:deckhand_core/deckhand_core.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'flash_sentinel.dart';

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
  ProcessElevatedHelperService({
    required this.helperPath,
    this.sentinelWriter,
    this.readOutputRoot,
  });

  /// Absolute path to the `deckhand-elevated-helper` binary.
  final String helperPath;

  /// When non-null, [writeImage] persists a flash-sentinel before
  /// launching the helper and clears it only after observing the
  /// helper's `event: done`. Production wiring constructs this with
  /// the per-user `<data_dir>/Deckhand/state/flash-sentinels/`
  /// directory; tests that don't care about sentinels leave it null.
  final FlashSentinelWriter? sentinelWriter;

  /// Deckhand-owned directory the elevated helper may write eMMC
  /// backup images into. The helper independently enforces this path
  /// policy, but the caller must pass the root so the elevated process
  /// can verify `--output` is a direct child before opening it.
  final String? readOutputRoot;

  @override
  Stream<FlashProgress> readImage({
    required String diskId,
    required String outputPath,
    required String confirmationToken,
    int totalBytes = 0,
    String? outputRoot,
  }) {
    final effectiveOutputRoot = outputRoot ?? readOutputRoot;
    if (effectiveOutputRoot == null || effectiveOutputRoot.trim().isEmpty) {
      return Stream.error(
        StateError('elevated read-image output root not configured'),
      );
    }
    return _launchCancellableHelper(
      confirmationToken: confirmationToken,
      buildArgs: (tokenFile, cancelFile) => <String>[
        'read-image',
        '--target', diskId,
        '--output', outputPath,
        '--output-root', effectiveOutputRoot,
        '--token-file', tokenFile,
        '--cancel-file', cancelFile,
        // Pass the size hint when the caller has it (the disk picker
        // upstream of S148 already enumerated sizeBytes via
        // listDisks()). Without this, Windows raw-device reads emit
        // bytes_total: 0 for every progress event.
        if (totalBytes > 0) ...['--total-bytes', '$totalBytes'],
        // The unprivileged Flutter parent can't terminate an elevated
        // child once UAC has approved it. Hand the helper our PID so
        // it can self-terminate when we go away (user closes Deckhand
        // mid-backup, app crash, etc.). Without this, an aborted UI
        // flow leaves the elevated process churning the disk in the
        // background until the operation completes naturally.
        '--watchdog-pid', '$pid',
      ],
    );
  }

  @override
  Stream<FlashProgress> hashDevice({
    required String diskId,
    required String confirmationToken,
    int totalBytes = 0,
  }) {
    return _launchCancellableHelper(
      confirmationToken: confirmationToken,
      buildArgs: (tokenFile, cancelFile) => <String>[
        'hash-device',
        '--target',
        diskId,
        '--token-file',
        tokenFile,
        '--cancel-file',
        cancelFile,
        if (totalBytes > 0) ...['--total-bytes', '$totalBytes'],
        '--watchdog-pid',
        '$pid',
      ],
    );
  }

  Stream<FlashProgress> _launchCancellableHelper({
    required String confirmationToken,
    required List<String> Function(String tokenFile, String cancelFile)
    buildArgs,
  }) {
    final controller = StreamController<FlashProgress>();
    Directory? tokenDir;
    Directory? cancelDir;
    File? cancelFile;
    StreamSubscription<FlashProgress>? helperSub;
    var cancelRequested = false;

    Future<void> closeController() async {
      if (!controller.isClosed) await controller.close();
    }

    Future<void> cleanupFiles() async {
      final liveCancelFile = cancelFile;
      if (liveCancelFile != null) {
        try {
          if (await liveCancelFile.exists()) await liveCancelFile.delete();
        } catch (_) {}
      }
      final liveCancelDir = cancelDir;
      if (liveCancelDir != null) {
        try {
          if (await liveCancelDir.exists()) {
            await liveCancelDir.delete(recursive: true);
          }
        } catch (_) {}
      }
      final liveTokenDir = tokenDir;
      if (liveTokenDir != null) {
        try {
          if (await liveTokenDir.exists()) {
            await liveTokenDir.delete(recursive: true);
          }
        } catch (_) {}
      }
    }

    Future<File> writePrivateTempFile({
      required String dirPrefix,
      required String fileName,
      required String body,
    }) async {
      final dir = await Directory.systemTemp.createTemp(dirPrefix);
      if (!Platform.isWindows) {
        await Process.run('chmod', ['0700', dir.path]);
      }
      final file = File(p.join(dir.path, fileName));
      await file.writeAsString(body, flush: true);
      if (!Platform.isWindows) {
        await Process.run('chmod', ['0600', file.path]);
      }
      if (dirPrefix == 'deckhand-tok-') {
        tokenDir = dir;
      } else {
        cancelDir = dir;
      }
      return file;
    }

    controller.onListen = () async {
      try {
        final tokenFile = await writePrivateTempFile(
          dirPrefix: 'deckhand-tok-',
          fileName: 'token',
          body: confirmationToken,
        );
        cancelFile = await writePrivateTempFile(
          dirPrefix: 'deckhand-cancel-',
          fileName: 'active',
          body: 'active',
        );
        if (cancelRequested) {
          await cleanupFiles();
          await closeController();
          return;
        }

        helperSub = launchHelper(buildArgs(tokenFile.path, cancelFile!.path))
            .listen(
              (event) {
                if (!controller.isClosed) controller.add(event);
              },
              onError: (Object e, StackTrace st) async {
                if (!controller.isClosed) controller.addError(e, st);
                await cleanupFiles();
                await closeController();
              },
              onDone: () async {
                await cleanupFiles();
                await closeController();
              },
            );
      } catch (e, st) {
        await cleanupFiles();
        if (!controller.isClosed) controller.addError(e, st);
        await closeController();
      }
    };

    controller.onCancel = () async {
      cancelRequested = true;
      await cleanupFiles();
      unawaited(helperSub?.cancel() ?? Future<void>.value());
    };

    return controller.stream;
  }

  @override
  Stream<FlashProgress> writeImage({
    required String imagePath,
    required String diskId,
    required String confirmationToken,
    bool verifyAfterWrite = true,
    String? expectedSha256,
  }) async* {
    // Write the token to a 0600-mode regular file in a 0700-mode
    // private temp dir, so the value never appears in /proc/<pid>/cmdline,
    // ps output, or the equivalent OS process table. The helper reads
    // the file and removes it before any other I/O; we also clean up
    // best-effort here in case the helper exits abnormally.
    final tokenDir = await Directory.systemTemp.createTemp('deckhand-tok-');
    if (!Platform.isWindows) {
      // chmod the dir 0700 explicitly; createTemp already does on
      // *nix but be defensive against future platform changes.
      await Process.run('chmod', ['0700', tokenDir.path]);
    }
    final tokenFile = File(p.join(tokenDir.path, 'token'));
    await tokenFile.writeAsString(confirmationToken, flush: true);
    if (!Platform.isWindows) {
      await Process.run('chmod', ['0600', tokenFile.path]);
    }

    final args = <String>[
      'write-image',
      '--image', imagePath,
      '--target', diskId,
      '--token-file', tokenFile.path,
      '--verify', verifyAfterWrite.toString(),
      if (expectedSha256 != null) ...['--sha256', expectedSha256],
      // Self-terminate when the unprivileged parent (this process)
      // dies — see the read-image branch for the rationale.
      '--watchdog-pid', '$pid',
    ];

    // Sentinel goes down before the elevation prompt fires. Anything
    // that interrupts the operation between here and `event: done`
    // — helper crash, UAC denial, user closing the app, power loss
    // — leaves the sentinel in place for the next disks.list to find.
    if (sentinelWriter != null) {
      try {
        await sentinelWriter!.write(
          diskId: diskId,
          imagePath: imagePath,
          imageSha256: expectedSha256,
        );
      } on FileSystemException {
        // A non-writable sentinel directory must not block the flash:
        // sentinels are diagnostic, not load-bearing for safety. The
        // user already cleared the destructive-op confirmation
        // dialog; refusing to flash here would be punitive.
      }
    }

    var sawDone = false;
    try {
      await for (final ev in launchHelper(args)) {
        if (ev.phase == FlashPhase.done) sawDone = true;
        yield ev;
      }
    } finally {
      if (sawDone && sentinelWriter != null) {
        await sentinelWriter!.clear(diskId);
      }
      // Best-effort token cleanup. The helper deletes the file on
      // read; this catches the case where it never got that far.
      try {
        await tokenDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Platform-specific launch surface, factored out so tests can
  /// substitute an in-memory event stream without spawning a real
  /// process. Production callers should not override this.
  @visibleForTesting
  Stream<FlashProgress> launchHelper(List<String> args) {
    if (Platform.isWindows) return _runWindows(args);
    if (Platform.isMacOS) return _runMacOs(args);
    return _runLinux(args);
  }

  // -----------------------------------------------------------------
  // Windows: PowerShell Start-Process -Verb RunAs. Helper output is
  // redirected to a tempfile; we tail it for JSON progress events.
  //
  // Race: the previous implementation's poll loop exited on
  // `ps.exitCode`, which was set the instant PowerShell finished —
  // but the stdout-redirected file might not have been flushed to
  // disk yet (NTFS buffers + PowerShell's own close sequence happen
  // asynchronously). The drain step tried to recover but mixed
  // string-index and byte-offset arithmetic, losing UTF-8 characters
  // or data held in `carry`. This rewrite does two things:
  //   1. Never exit the tail loop until we've done one read strictly
  //      after the process was observed as exited AND the file size
  //      has stopped growing. That guarantees the final progress
  //      event is observed even if it lands after exitCode fires.
  //   2. Use a single byte-offset + UTF-8 decoder across the loop and
  //      drain so partial characters or unfinished lines are never
  //      dropped between phases.

  Stream<FlashProgress> _runWindows(List<String> helperArgs) async* {
    // PowerShell's `Start-Process -Verb RunAs` does NOT honor
    // -RedirectStandardOutput because the elevated child is spawned
    // by Windows (ShellExecuteEx) rather than by PowerShell, and file
    // handles can't cross the elevation boundary. The helper is taught
    // a `--events-file <path>` flag that opens the file itself and
    // writes line-delimited JSON events into it. Same on-disk file as
    // far as both processes are concerned, so the parent's tail loop
    // keeps working.
    //
    // -RedirectStandardError is ALSO unsupported with -Verb RunAs:
    // the two parameters are in different parameter sets in both
    // Windows PowerShell 5.1 and PowerShell 7. Combining them throws
    // AmbiguousParameterSet (a NON-terminating error), which leaves
    // `$p` null. `exit $null.ExitCode` evaluates to `exit 0`, the
    // helper never launches, no UAC dialog appears, and the parent
    // sees "exit 0 + empty events file" — indistinguishable from a
    // UAC denial. Set ErrorActionPreference=Stop and wrap in
    // try/catch so any failure (param binding, UAC denial, missing
    // exe) is surfaced as a non-zero exit + a clear message on
    // PowerShell's own stderr, which the Dart parent drains.
    final stdoutFile = File(
      p.join(
        Directory.systemTemp.path,
        'deckhand-helper-${DateTime.now().millisecondsSinceEpoch}.log',
      ),
    );
    await stdoutFile.writeAsString('');

    final argsWithEventsFile = _injectHelperEventsFile(
      helperArgs,
      stdoutFile.path,
    );
    final argList = argsWithEventsFile.map(powerShellQuoteArg).join(',');

    // Two launch paths depending on whether we already have admin:
    //
    // 1. Already admin (EnableLUA=0, OR Deckhand was started via
    //    "Run as administrator", OR the user is in Administrators
    //    with a non-split token): launch the helper DIRECTLY without
    //    the `-Verb RunAs` dance. Critical for the EnableLUA=0
    //    case — `Start-Process -Verb RunAs` does NOT actually elevate
    //    when LUA is disabled (Windows treats `runas` differently),
    //    and the helper ends up running in a half-broken context
    //    that crashes silently before writing the "started" event.
    //
    // 2. Not admin: use `-Verb RunAs` to trigger UAC. This is the
    //    normal flow for the typical Windows user who runs Deckhand
    //    unprivileged with LUA on.
    //
    // The `IsInRole(Administrator)` check returns true exactly when
    // the current process token has the Administrators group active —
    // that's the right signal: "right now, can I do raw-device IO
    // without asking?". When EnableLUA=0 it's true for every admin
    // user; when LUA is on it's true only for already-elevated
    // processes.
    final psCommand = [
      '\$ErrorActionPreference = "Stop"; ',
      'try { ',
      '  \$isAdmin = ([Security.Principal.WindowsPrincipal] ',
      '    [Security.Principal.WindowsIdentity]::GetCurrent()).',
      '    IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator); ',
      '  if (\$isAdmin) { ',
      '    \$p = Start-Process -FilePath "$helperPath" ',
      '      -ArgumentList $argList ',
      '      -Wait -PassThru -WindowStyle Hidden; ',
      '  } else { ',
      '    \$p = Start-Process -FilePath "$helperPath" ',
      '      -ArgumentList $argList ',
      '      -Verb RunAs -Wait -PassThru; ',
      '  } ',
      '  exit \$p.ExitCode ',
      '} catch { ',
      // Write the failure to PowerShell's stderr so the Dart parent
      // can show the user something actionable: UAC denial reads
      // "The operation was canceled by the user.", missing exe reads
      // "This file does not have an app associated with it…", etc.
      '  [Console]::Error.WriteLine(\$_.Exception.Message); ',
      '  exit 1 ',
      '}',
    ].join();

    final ps = await Process.start('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      psCommand,
    ], runInShell: false);

    // Drain PowerShell's own stdout/stderr concurrently. Without
    // this, the OS pipe buffers can fill on a chatty error and
    // Process.exitCode hangs; more importantly we need the captured
    // stderr text to build the diagnostic when Start-Process itself
    // fails (parameter binding, UAC denial, exe missing).
    final psStdoutBuf = StringBuffer();
    final psStderrBuf = StringBuffer();
    final psStdoutDone = ps.stdout
        .transform(utf8.decoder)
        .listen(psStdoutBuf.write)
        .asFuture<void>();
    final psStderrDone = ps.stderr
        .transform(utf8.decoder)
        .listen(psStderrBuf.write)
        .asFuture<void>();

    final exitFuture = ps.exitCode;
    var processExited = false;
    exitFuture.then((_) => processExited = true);

    var offset = 0;
    final decoder = const Utf8Decoder(allowMalformed: true);
    final carry = StringBuffer();

    Future<List<FlashProgress>> readChunkOnce() async {
      final events = <FlashProgress>[];
      final len = await stdoutFile.length();
      if (len <= offset) return events;
      final raf = await stdoutFile.open();
      try {
        await raf.setPosition(offset);
        final bytes = await raf.read(len - offset);
        offset = len;
        final chunk = decoder.convert(bytes);
        carry.write(chunk);
        var s = carry.toString();
        var nl = s.indexOf('\n');
        while (nl >= 0) {
          final line = s.substring(0, nl).trimRight();
          s = s.substring(nl + 1);
          final ev = _parseHelperLine(line);
          if (ev != null) events.add(ev);
          nl = s.indexOf('\n');
        }
        carry
          ..clear()
          ..write(s);
      } finally {
        await raf.close();
      }
      return events;
    }

    Future<String?> readEventsTail() async {
      try {
        if (!await stdoutFile.exists()) return null;
        var eventsTail = (await stdoutFile.readAsString()).trim();
        if (eventsTail.length > 512) {
          eventsTail = eventsTail.substring(eventsTail.length - 512);
        }
        return eventsTail;
      } catch (_) {
        return null;
      }
    }

    var keepDebugFiles = false;
    try {
      while (!processExited) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        for (final ev in await readChunkOnce()) {
          yield ev;
        }
      }
      // Drain after exit: PowerShell may still be flushing redirected
      // stdout. Keep reading until the file size is stable across two
      // passes so we can't miss the final `done` event.
      await exitFuture;
      var stableSize = -1;
      for (var i = 0; i < 20; i++) {
        for (final ev in await readChunkOnce()) {
          yield ev;
        }
        final size = await stdoutFile.length();
        if (size == stableSize && size == offset) break;
        stableSize = size;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      // Any unterminated trailing line gets one last parse attempt.
      if (carry.isNotEmpty) {
        final ev = _parseHelperLine(carry.toString().trimRight());
        if (ev != null) yield ev;
        carry.clear();
      }

      final exit = await exitFuture;
      // Read the events-file + PowerShell streams unconditionally;
      // we want their contents in any error message even when the
      // parent exited 0. The previous version only surfaced output
      // on non-zero exit, which missed the failure mode where
      // powershell returns 0 but the helper produced no events (UAC
      // denied, helper crashed, events-file not writable, …). The
      // user just sees "no completion event" with no diagnostic to
      // act on.
      await Future.wait<void>([psStdoutDone, psStderrDone]);
      String? errTail = psStderrBuf.toString().trim();
      if (errTail.isEmpty) errTail = null;
      if (errTail != null && errTail.length > 512) {
        errTail = errTail.substring(errTail.length - 512);
      }
      // PowerShell's stdout for our script is normally empty (we
      // only `exit`); surface it on failure in case a future tweak
      // emits diagnostic output.
      final psOut = psStdoutBuf.toString().trim();
      var eventsTail = await readEventsTail();

      // The helper writes a "started" sentinel event the moment it
      // begins executing — we use that to tell three failure modes
      // apart: helper never launched (events file empty + no
      // .openerr), helper couldn't open the events file (.openerr
      // sidecar exists), or helper ran but didn't reach `done`
      // (started event present but no done).
      final openErrFile = File('${stdoutFile.path}.openerr');
      String? openErrTail;
      try {
        if (await openErrFile.exists()) {
          openErrTail = (await openErrFile.readAsString()).trim();
        }
      } catch (_) {}
      var sawStartedEvent = _helperEventsContainStarted(eventsTail);

      // In "never notify" UAC mode, ShellExecute/Start-Process can
      // report success before the elevated process has had time to
      // open the events file. Do not treat PowerShell exit 0 as helper
      // completion; wait briefly for the helper's own started event.
      if (exit == 0 && !sawStartedEvent) {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 150));
          for (final ev in await readChunkOnce()) {
            yield ev;
          }
          eventsTail = await readEventsTail();
          sawStartedEvent = _helperEventsContainStarted(eventsTail);
          if (sawStartedEvent ||
              _helperEventsContainDone(eventsTail) ||
              _lastHelperErrorMessage(eventsTail) != null) {
            break;
          }
        }
      }

      // If PowerShell returned before the elevated helper finished,
      // keep tailing the helper-owned events file until the helper
      // emits a terminal event. This preserves progress and prevents
      // a live backup from being misreported as "never started".
      var helperError = _lastHelperErrorMessage(eventsTail);
      var sawDoneEvent = _helperEventsContainDone(eventsTail);
      if (exit == 0 &&
          sawStartedEvent &&
          !sawDoneEvent &&
          helperError == null) {
        var lastLength = await stdoutFile.length();
        var idleSince = DateTime.now();
        while (DateTime.now().difference(idleSince) <
            const Duration(seconds: 45)) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          for (final ev in await readChunkOnce()) {
            yield ev;
          }
          final len = await stdoutFile.length();
          if (len != lastLength) {
            lastLength = len;
            idleSince = DateTime.now();
          }
          eventsTail = await readEventsTail();
          helperError = _lastHelperErrorMessage(eventsTail);
          sawDoneEvent = _helperEventsContainDone(eventsTail);
          if (sawDoneEvent || helperError != null) break;
        }
      }

      // UAC denial: ShellExecuteEx → Start-Process throws an
      // exception with this exact message ("The operation was
      // canceled by the user."). Our PowerShell try/catch turns it
      // into exit 1 + this string on stderr. Detect it before the
      // generic "exited with code N" branch so the user sees a
      // human-readable message instead of a stack-tracey blob.
      if (errTail != null &&
          errTail.contains('The operation was canceled by the user')) {
        throw ElevatedHelperException(
          'UAC prompt was denied. Click "Yes" on the Windows '
          'elevation prompt to allow the backup, then try again.',
        );
      }
      if (exit != 0) {
        if (helperError != null) {
          throw ElevatedHelperException(helperError);
        }
        if (sawDoneEvent) {
          return;
        }
        throw ElevatedHelperException(
          'elevated helper exited with code $exit'
          '${errTail == null || errTail.isEmpty ? "" : "\npowershell stderr: $errTail"}'
          '${psOut.isEmpty ? "" : "\npowershell stdout: $psOut"}'
          '${openErrTail == null || openErrTail.isEmpty ? "" : "\nopen-error: $openErrTail"}'
          '${eventsTail == null || eventsTail.isEmpty ? "" : "\nevents: $eventsTail"}',
        );
      }
      if (openErrTail != null && openErrTail.isNotEmpty) {
        throw ElevatedHelperException(
          'helper could not write to its events-file:\n$openErrTail\n'
          'This usually means the file path was mangled by '
          '`Start-Process -Verb RunAs` or the elevated process can\'t '
          'write to the user-temp path. Path attempted: ${stdoutFile.path}',
        );
      }
      if (helperError != null) {
        throw ElevatedHelperException(helperError);
      }
      if (!sawStartedEvent) {
        final recovered = await _recoverCompletedReadImage(helperArgs);
        if (recovered != null) {
          yield recovered;
          return;
        }
        // No "started" sentinel + exit 0 = the helper was NEVER
        // launched. With ErrorActionPreference=Stop + try/catch in
        // the PowerShell wrapper, this should now only happen if
        // Windows itself swallowed the launch (rare): antivirus
        // quarantine of the helper exe, missing manifest, etc.
        throw ElevatedHelperException(
          'elevated helper never started. '
          'The UAC prompt may have been suppressed or the elevated '
          'process couldn\'t be launched (antivirus quarantine, '
          'helper missing, missing manifest, etc.). '
          'Helper path: $helperPath. Events-file: ${stdoutFile.path} (empty). '
          'PowerShell stderr: ${errTail ?? "(empty)"}',
        );
      }
      if (!sawDoneEvent) {
        final recovered = await _recoverCompletedReadImage(helperArgs);
        if (recovered != null) {
          yield recovered;
          return;
        }
        // Started but didn't reach done. The op body failed mid-flight
        // without going through fatalf — surface whatever events we
        // did see + any stderr.
        throw ElevatedHelperException(
          'elevated helper started but never reported completion.\n'
          'events tail:\n${eventsTail ?? "(empty)"}\n'
          'powershell stderr: ${errTail ?? "(empty)"}',
        );
      }
    } catch (_) {
      keepDebugFiles = true;
      rethrow;
    } finally {
      if (!keepDebugFiles) {
        for (final f in [stdoutFile, File('${stdoutFile.path}.openerr')]) {
          try {
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
      }
    }
  }

  // -----------------------------------------------------------------
  // macOS: osascript with administrator privileges. Helper stdout is
  // captured line-by-line.

  Stream<FlashProgress> _runMacOs(List<String> helperArgs) async* {
    // Build a single shell command line from helperPath + each arg,
    // POSIX-quoted in-line, and pass it directly to `do shell script`.
    // The previous implementation wrote a one-shot script to a temp
    // file - that opened a TOCTOU window between writeAsString and
    // osascript's exec where a same-user attacker could have replaced
    // the file. There is no script file to race in this version: the
    // command is a literal string in the AppleScript source.
    final shellCmd = StringBuffer(_shellQuote(helperPath));
    for (final a in helperArgs) {
      shellCmd
        ..write(' ')
        ..write(_shellQuote(a));
    }
    // AppleScript string literal: escape backslash and double-quote
    // only. The shell-level quoting above already neutralised every
    // shell metacharacter, so the AppleScript layer just needs to
    // preserve the bytes through to /bin/sh.
    final aquoted = shellCmd
        .toString()
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"');
    final appleScript =
        'do shell script "$aquoted" with administrator privileges';
    final proc = await Process.start('osascript', ['-e', appleScript]);
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

/// Non-destructive elevated-helper stand-in used for whole-app dry-run
/// mode. This closes the gap where the sidecar flash service was
/// dry-run aware but the app still had a real privileged helper wired.
class DryRunElevatedHelperService implements ElevatedHelperService {
  const DryRunElevatedHelperService();

  @override
  Stream<FlashProgress> hashDevice({
    required String diskId,
    required String confirmationToken,
    int totalBytes = 0,
  }) => _dryRunHelperProgress(
    label: 'DRY-RUN elevated hash $diskId',
    totalBytes: totalBytes,
  );

  @override
  Stream<FlashProgress> readImage({
    required String diskId,
    required String outputPath,
    required String confirmationToken,
    int totalBytes = 0,
    String? outputRoot,
  }) => _dryRunHelperProgress(
    label: 'DRY-RUN elevated read $diskId -> $outputPath',
    totalBytes: totalBytes,
  );

  @override
  Stream<FlashProgress> writeImage({
    required String imagePath,
    required String diskId,
    required String confirmationToken,
    bool verifyAfterWrite = true,
    String? expectedSha256,
  }) => _dryRunHelperProgress(
    label: 'DRY-RUN elevated write $imagePath -> $diskId',
  );
}

Stream<FlashProgress> _dryRunHelperProgress({
  required String label,
  int totalBytes = 0,
}) async* {
  final total = totalBytes > 0 ? totalBytes : 1024 * 1024 * 1024;
  yield FlashProgress(
    bytesDone: 0,
    bytesTotal: total,
    phase: FlashPhase.preparing,
    message: label,
  );
  await Future<void>.delayed(const Duration(milliseconds: 50));
  for (final pct in const [0.25, 0.5, 0.75, 1.0]) {
    yield FlashProgress(
      bytesDone: (total * pct).round(),
      bytesTotal: total,
      phase: FlashPhase.writing,
      message: label,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  yield FlashProgress(
    bytesDone: total,
    bytesTotal: total,
    phase: FlashPhase.done,
    message: '$label (simulated)',
  );
}

/// Test-only re-export of [_parseHelperLine]. The platform-specific
/// `_runWindows` / `_runMacOs` / `_runLinux` paths can't be unit-
/// tested without spawning a real elevated process, but the parser
/// they all funnel through is OS-agnostic and load-bearing — every
/// `event:done` / `event:error` line the helper emits goes through
/// here. Tests use this seam to pin the contract.
@visibleForTesting
FlashProgress? parseHelperLineForTesting(String line) => _parseHelperLine(line);

@visibleForTesting
List<String> injectHelperEventsFileForTesting(
  List<String> helperArgs,
  String eventsPath,
) => _injectHelperEventsFile(helperArgs, eventsPath);

@visibleForTesting
bool helperEventsContainDoneForTesting(String? events) =>
    _helperEventsContainDone(events);

@visibleForTesting
bool helperEventsContainStartedForTesting(String? events) =>
    _helperEventsContainStarted(events);

@visibleForTesting
String? lastHelperErrorMessageForTesting(String? events) =>
    _lastHelperErrorMessage(events);

@visibleForTesting
Future<FlashProgress?> recoverCompletedReadImageForTesting(
  List<String> helperArgs,
) => _recoverCompletedReadImage(helperArgs);

List<String> _injectHelperEventsFile(
  List<String> helperArgs,
  String eventsPath,
) {
  if (helperArgs.isEmpty) {
    return ['--events-file', eventsPath];
  }
  return [helperArgs.first, '--events-file', eventsPath, ...helperArgs.skip(1)];
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

bool _helperEventsContainDone(String? events) {
  if (events == null || events.trim().isEmpty) return false;
  for (final obj in _decodeHelperEvents(events)) {
    if (obj['event'] == 'done') return true;
  }
  return false;
}

bool _helperEventsContainStarted(String? events) {
  if (events == null || events.trim().isEmpty) return false;
  for (final obj in _decodeHelperEvents(events)) {
    if (obj['event'] == 'started') return true;
  }
  return false;
}

String? _lastHelperErrorMessage(String? events) {
  if (events == null || events.trim().isEmpty) return null;
  String? last;
  for (final obj in _decodeHelperEvents(events)) {
    if (obj['event'] == 'error') {
      final msg = obj['message'];
      if (msg is String && msg.trim().isNotEmpty) {
        last = msg.trim();
      }
    }
  }
  return last;
}

Future<FlashProgress?> _recoverCompletedReadImage(
  List<String> helperArgs,
) async {
  if (helperArgs.isEmpty || helperArgs.first != 'read-image') return null;
  final outputPath = _argAfter(helperArgs, '--output');
  final totalText = _argAfter(helperArgs, '--total-bytes');
  final total = int.tryParse(totalText ?? '') ?? 0;
  if (outputPath == null || outputPath.trim().isEmpty || total <= 0) {
    return null;
  }

  final file = File(outputPath);
  if (!await file.exists()) return null;
  final length = await file.length();
  if (length != total) return null;

  final digest = await sha256.bind(file.openRead()).first;
  return FlashProgress(
    bytesDone: length,
    bytesTotal: total,
    phase: FlashPhase.done,
    message: digest.toString(),
  );
}

String? _argAfter(List<String> args, String flag) {
  final i = args.indexOf(flag);
  if (i < 0 || i + 1 >= args.length) return null;
  return args[i + 1];
}

Iterable<Map<String, dynamic>> _decodeHelperEvents(String events) sync* {
  for (final line in const LineSplitter().convert(events)) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    try {
      final obj = jsonDecode(trimmed);
      if (obj is Map<String, dynamic>) yield obj;
    } catch (_) {
      continue;
    }
  }
}

FlashPhase _phaseFromString(String? s) => switch (s) {
  'writing' || 'reading' => FlashPhase.writing,
  'verifying' || 'write-complete' || 'verified' => FlashPhase.verifying,
  'done' => FlashPhase.done,
  'failed' => FlashPhase.failed,
  _ => FlashPhase.preparing,
};

// Delegate to the canonical helper in deckhand_core so every corner of
// the app uses the same implementation. Shim kept as a thin wrapper to
// avoid touching the call sites.
String _shellQuote(String s) => shellSingleQuote(s);

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
