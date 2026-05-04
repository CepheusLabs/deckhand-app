// Install/apply step bodies split out of wizard_controller.dart so the
// main controller stays under the project's 800-line ceiling. All of
// these are top-level private helpers that take the controller as
// their first argument; they share WizardController's library-private
// scope because this file is `part of 'wizard_controller.dart'`.
part of 'wizard_controller.dart';

Future<void> _runInstallFirmwareImpl(
  WizardController c,
  Map<String, dynamic> step,
) async {
  final s = c._requireSession();
  final fw = c._selectedFirmware();
  if (fw == null) throw StepExecutionException('no firmware selected');
  _validateHttpsGitRepoImpl(fw.repo, 'firmware repo');
  _validateGitRefImpl(fw.ref, 'firmware ref');
  final install = fw.installPath ?? '~/klipper';
  c._log(step, '[firmware] cloning ${fw.repo} @ ${fw.ref} -> $install');
  // Every profile-supplied value is untrusted input. Paths with `~`
  // need tilde-expansion, so use shellPathEscape; refs and repo URLs
  // get single-quoted.
  final qInstall = shellPathEscape(install);
  final qRef = shellSingleQuote(fw.ref);
  final qRepo = shellSingleQuote(fw.repo);
  // `--progress` forces git to print progress lines even when stderr
  // isn't a TTY (which it isn't for a `dartssh` exec channel). Without
  // it git stays silent until the clone completes and the user sees
  // a 30-90s "starting install_firmware" gap with no signal that the
  // download is happening.
  final cloneCmd =
      'if [ -d $qInstall/.git ]; then cd $qInstall && git fetch --progress origin && git checkout $qRef && git pull --ff-only; '
      'else rm -rf -- $qInstall && git clone --progress --depth 1 -b $qRef -- $qRepo $qInstall; fi';
  final cloneStderr = StringBuffer();
  final stepId = step['id'] as String? ?? '';
  // Kick off an immediate progress event so the bar stops sitting at
  // "starting install_firmware …" before git's first chunk arrives.
  // Some git versions buffer their first progress line for a couple
  // of seconds, which on a slow network looks like the wizard hung.
  c._emit(
    StepProgress(stepId: stepId, percent: 0.01, message: 'cloning ${fw.repo}'),
  );
  // Track which phases we've already echoed to the log so the user
  // gets one summary line per phase (Counting, Compressing, Receiving,
  // Resolving) instead of either silence or a flood. The progress bar
  // updates continuously from every line; the log only gets an entry
  // when a phase first reports progress, plus a final "clone done".
  final loggedPhases = <String>{};
  await for (final line
      in c.ssh
          .runStreamMerged(s, cloneCmd)
          .timeout(const Duration(minutes: 10))) {
    cloneStderr.writeln(line);
    final progress = _parseGitProgress(line);
    if (progress != null) {
      c._emit(
        StepProgress(
          stepId: stepId,
          percent: progress.fraction,
          message: progress.message,
        ),
      );
      if (loggedPhases.add(progress.phase)) {
        c._log(step, '[firmware] ${progress.phase}…');
      }
    }
  }
  // Verify the clone landed by checking the repo exists. Streaming
  // doesn't surface an exit code, so we re-check state instead.
  final verify = await c._runSsh(
    'test -d $qInstall/.git && git -C $qInstall rev-parse --abbrev-ref HEAD',
    timeout: const Duration(seconds: 30),
  );
  if (!verify.success) {
    throw StepExecutionException(
      'clone failed',
      stderr: cloneStderr.toString(),
    );
  }
  // Explicit "clone done" / "starting venv" log lines so the user can
  // tell from the log alone where the install actually is. Without
  // this the log shows just the initial "[firmware] cloning …" line
  // and the header header silently moves on to "preparing python
  // environment", which reads as a UI bug ("why does the top say
  // Python while the log still says cloning?").
  c._log(step, '[firmware] clone done');
  c._log(step, '[firmware] preparing python environment');
  // Reset progress so the venv step starts from a clean bar instead
  // of inheriting the clone's "100%".
  c._emit(
    StepProgress(
      stepId: stepId,
      percent: 0.0,
      message: 'preparing python environment',
    ),
  );

  final venv = fw.venvPath ?? '~/klippy-env';
  final qVenv = shellPathEscape(venv);
  final venvCmd =
      'PY=\$(command -v python3.11 || command -v python3) && \$PY -m venv $qVenv && '
      '$qVenv/bin/pip install --quiet -U pip setuptools wheel && '
      '$qVenv/bin/pip install --quiet -r $qInstall/scripts/klippy-requirements.txt';
  final venvRes = await c._runSsh(
    venvCmd,
    timeout: const Duration(minutes: 15),
  );
  if (!venvRes.success) {
    throw StepExecutionException('venv setup failed', stderr: venvRes.stderr);
  }
  c._log(step, '[firmware] venv ready at $venv');
}

/// Parse a single git --progress output line into a normalized
/// fraction + phase + human-readable label. Git emits progress like:
///   `Receiving objects:  37% (370/1000), 1.5 MiB | 3.2 MiB/s`
///   `Resolving deltas:  82% (164/200)`
/// We weight `Receiving objects` to 0.10..0.85 and `Resolving deltas`
/// to 0.85..1.0 so the bar moves forward across both phases instead
/// of hitting 100% during receive and resetting during resolve. The
/// phase name is returned separately so the install step can emit
/// one log line per phase ("[firmware] Receiving objects…") without
/// flooding the log on every percent tick.
({double fraction, String phase, String message})? _parseGitProgress(
  String line,
) {
  final m = RegExp(
    r'^(Receiving objects|Resolving deltas|Counting objects|Compressing objects):\s+(\d+)%',
  ).firstMatch(line);
  if (m == null) return null;
  final phase = m.group(1)!;
  final pct = int.parse(m.group(2)!);
  final p = pct / 100.0;
  final fraction = switch (phase) {
    'Counting objects' => p * 0.05,
    'Compressing objects' => 0.05 + p * 0.05,
    'Receiving objects' => 0.10 + p * 0.75,
    'Resolving deltas' => 0.85 + p * 0.15,
    _ => p,
  };
  return (fraction: fraction.clamp(0.0, 1.0), phase: phase, message: line);
}

Future<void> _runLinkExtrasImpl(
  WizardController c,
  Map<String, dynamic> step,
) async {
  final s = c._requireSession();
  final fw = c._selectedFirmware();
  if (fw == null) throw StepExecutionException('no firmware selected');
  final install = fw.installPath ?? '~/klipper';
  final sources = ((step['sources'] as List?) ?? const []).cast<String>();
  // Make sure the destination tree exists ONCE up front so single-file
  // uploads below have somewhere to land. SFTP itself can't expand
  // `~`; running `mkdir -p` via shell does, and a single round-trip
  // covers every source we're about to push.
  final qExtras = shellPathEscape('$install/klippy/extras');
  final mk = await c._runSsh('mkdir -p -- $qExtras');
  if (!mk.success) {
    throw StepExecutionException('remote mkdir failed', stderr: mk.stderr);
  }
  for (final src in sources) {
    final localPath = c._resolveProfilePath(src);
    final basename = p.basename(localPath);
    final remote = '$install/klippy/extras/$basename';
    if (await Directory(localPath).exists()) {
      await c._uploadDir(localPath, remote);
    } else {
      // SFTP doesn't expand `~`; OpenSSH's SFTP subsystem defaults the
      // cwd to the user's home, so dropping the `~/` prefix gives a
      // path that resolves correctly. Absolute paths pass through.
      final sftpPath = remote.startsWith('~/') ? remote.substring(2) : remote;
      await c.ssh.upload(s, localPath, sftpPath);
    }
    c._log(step, '[link_extras] installed $basename');
  }
}

Future<void> _runInstallStackImpl(
  WizardController c,
  Map<String, dynamic> step,
) async {
  c._requireSession();
  final rawComponents = ((step['components'] as List?) ?? const [])
      .cast<String>();
  // Expand the `{{stack.webui.selected}}` token into the user's actual
  // webui choices. The profile's `components: [moonraker,
  // "{{stack.webui.selected}}", kiauh, crowsnest]` expects this slot
  // to carry the user's pick(s) — one entry when they picked one
  // (fluidd or mainsail), zero entries when they picked "Neither",
  // multiple when they picked Both. The general `_render` engine
  // can't fan one token into many list entries, so the expansion
  // happens here.
  final webuiSelected = ((c._state.decisions['webui'] as List?) ?? const [])
      .cast<String>();
  final components = <String>[];
  for (final raw in rawComponents) {
    final stripped = raw.trim();
    if (stripped == '{{stack.webui.selected}}') {
      components.addAll(webuiSelected);
      continue;
    }
    // Non-webui tokens still go through the standard renderer for
    // any decisions./profile./firmware. tokens they may carry.
    components.add(c._render(raw));
  }
  final stack = c._profile!.stack;
  for (final spec in components) {
    final name = spec.replaceAll('?', '');
    final optional = spec.endsWith('?');
    if (name.isEmpty) continue;
    final cfg = c._stackComponent(stack, name);
    if (cfg == null) {
      if (optional) continue;
      throw StepExecutionException('unknown stack component $name');
    }
    if (name == 'kiauh' && c._state.decisions['kiauh'] == false) {
      c._log(step, '[stack] kiauh skipped by user');
      continue;
    }
    final repo = cfg['repo'] as String?;
    final ref = cfg['ref'] as String? ?? 'master';
    final install = cfg['install_path'] as String?;
    final releaseRepo = cfg['release_repo'] as String?;
    final assetPattern = cfg['asset_pattern'] as String?;
    final assetSha256 = cfg['sha256'] as String?;

    if (repo != null && install != null) {
      _validateHttpsGitRepoImpl(repo, '$name repo');
      _validateGitRefImpl(ref, '$name ref');
      // Source-based install: shallow git clone on the printer.
      final qInstall = shellPathEscape(install);
      final qRef = shellSingleQuote(ref);
      final qRepo = shellSingleQuote(repo);
      final cmd =
          'if [ -d $qInstall/.git ]; then cd $qInstall && git pull --ff-only; '
          'else git clone --depth 1 -b $qRef -- $qRepo $qInstall; fi';
      final res = await c._runSsh(cmd, timeout: const Duration(minutes: 10));
      if (!res.success) {
        throw StepExecutionException('$name clone failed', stderr: res.stderr);
      }
    } else if (releaseRepo != null && assetPattern != null && install != null) {
      if (assetSha256 == null || assetSha256.trim().isEmpty) {
        throw StepExecutionException(
          '$name release asset is missing required sha256',
        );
      }
      // Release-asset install (Fluidd/Mainsail/etc.): pull the zip
      // from GitHub Releases on the host, push it to the printer,
      // and unzip in place. Direct on-printer downloads aren't
      // viable on locked-down stock OSes that may not have a
      // working CA bundle or modern enough TLS for api.github.com.
      final hostTmp = p.join(
        Directory.systemTemp.path,
        'deckhand-$name-${c._randomSuffix()}.zip',
      );
      final fetched = await c.upstream.releaseFetch(
        repoSlug: releaseRepo,
        assetPattern: assetPattern,
        destPath: hostTmp,
        expectedSha256: assetSha256,
      );
      // SFTP cwd defaults to home on OpenSSH; absolute /tmp/ avoids
      // tilde-expansion concerns and ensures predictable cleanup.
      final remoteZip = '/tmp/deckhand-$name-${c._randomSuffix()}.zip';
      final session = c._requireSession();
      await c.ssh.upload(session, fetched.localPath, remoteZip);
      final qInstall = shellPathEscape(install);
      final qZip = shellSingleQuote(remoteZip);
      // Some target boxes ship `unzip` and others don't — try unzip
      // first, fall back to busybox unzip, and surface a clear error
      // if neither is available.
      final extract =
          'mkdir -p -- $qInstall && '
          '(command -v unzip >/dev/null && unzip -q -o $qZip -d $qInstall '
          ' || (command -v busybox >/dev/null && busybox unzip -o $qZip -d $qInstall) '
          ' || (echo "no unzip available" >&2; exit 127)) && '
          'rm -f -- $qZip';
      final res = await c._runSsh(extract, timeout: const Duration(minutes: 5));
      if (!res.success) {
        throw StepExecutionException(
          '$name extract failed',
          stderr: res.stderr,
        );
      }
    }
    c._log(step, '[stack] $name installed');
  }
}

Future<void> _runApplyServicesImpl(
  WizardController c,
  Map<String, dynamic> step,
) async {
  c._requireSession();
  for (final svc in c._profile!.stockOs.services) {
    final action =
        c._state.decisions['service.${svc.id}'] as String? ?? svc.defaultAction;
    final unit = svc.raw['systemd_unit'] as String?;
    final proc = svc.raw['process_pattern'] as String?;
    switch (action) {
      case 'remove':
      case 'disable':
        if (unit != null) {
          // systemd_unit is profile-supplied; always quote and end
          // option parsing before the unit name.
          final qUnit = shellSingleQuote(unit);
          await c._runSsh(
            'sudo systemctl disable --now -- $qUnit 2>/dev/null || true',
          );
        }
        if (proc != null) {
          // process_pattern is profile-supplied. Double-quoting is
          // not enough (it leaves $()/backticks live), so we single-
          // quote and pass to pkill -f as one argument.
          final qProc = shellSingleQuote(proc);
          await c._runSsh('sudo pkill -f -- $qProc 2>/dev/null || true');
        }
        c._log(step, '[services] ${svc.id}: disabled');
      case 'stub':
        c._log(step, '[services] ${svc.id}: left as stub');
      default:
        c._log(step, '[services] ${svc.id}: keeping');
    }
  }
}

Future<void> _runApplyFilesImpl(
  WizardController c,
  Map<String, dynamic> step,
) async {
  c._requireSession();
  for (final f in c._profile!.stockOs.files) {
    final decision =
        c._state.decisions['file.${f.id}'] as String? ?? f.defaultAction;
    if (decision != 'delete') continue;
    for (final path in f.paths) {
      if (c._isDangerousPath(path)) {
        c._log(step, '[files] SKIPPING dangerous path: $path');
        continue;
      }
      final String cmd;
      if (c._hasGlob(path)) {
        // Glob path: `find <dir> -maxdepth 1 -name <pattern> -delete`
        // handles the expansion itself (so the shell doesn't need to)
        // and cleanly no-ops when the pattern matches nothing. Only
        // the trailing segment is allowed to contain wildcards; the
        // parent directory must be a concrete path so we refuse to
        // recurse into anything unexpected.
        final dir = p.posix.dirname(path);
        final pattern = p.posix.basename(path);
        if (c._hasGlob(dir) || c._isDangerousPath(dir)) {
          c._log(step, '[files] SKIPPING unsafe glob directory: $dir');
          continue;
        }
        cmd =
            'sudo find ${c._shellQuote(dir)} -maxdepth 1 -name ${c._shellQuote(pattern)} -print -exec rm -rf -- {} +';
      } else {
        cmd = 'sudo rm -rf -- ${c._shellQuote(path)}';
      }
      final res = await c._runSsh(cmd);
      c._log(step, '[files] rm ${f.id}: $path (exit ${res.exitCode})');
      if (res.stdout.trim().isNotEmpty) {
        for (final line in res.stdout.trim().split('\n')) {
          c._log(step, '[files]   removed: $line');
        }
      }
    }
  }
}
