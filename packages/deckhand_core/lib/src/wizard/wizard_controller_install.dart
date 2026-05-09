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
  c._validateRemoteInstallPath(install, 'firmware install path');
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
  final stepId = _stringValue(step['id']) ?? '';
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
  c._validateRemoteInstallPath(venv, 'firmware venv path');
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
  final sources = _stringList(step['sources']);
  final targetDir = _stringValue(step['target_dir']);
  if (targetDir != null && targetDir.trim().isNotEmpty) {
    await _runTargetDirLinkExtras(c, step, sources);
    return;
  }

  final fw = c._selectedFirmware();
  if (fw == null) throw StepExecutionException('no firmware selected');
  final install = fw.installPath ?? '~/klipper';
  final resolvedSources = await _resolveLinkExtraSources(c, sources);
  // Make sure the destination tree exists ONCE up front so single-file
  // uploads below have somewhere to land. SFTP itself can't expand
  // `~`; running `mkdir -p` via shell does, and a single round-trip
  // covers every source we're about to push.
  final qExtras = shellPathEscape('$install/klippy/extras');
  final mk = await c._runSsh('mkdir -p -- $qExtras');
  if (!mk.success) {
    throw StepExecutionException('remote mkdir failed', stderr: mk.stderr);
  }
  for (final source in resolvedSources) {
    final remote = '$install/klippy/extras/${source.basename}';
    if (source.isDirectory) {
      await c._uploadDir(source.localPath, remote);
    } else {
      // SFTP doesn't expand `~`; OpenSSH's SFTP subsystem defaults the
      // cwd to the user's home, so dropping the `~/` prefix gives a
      // path that resolves correctly. Absolute paths pass through.
      final sftpPath = remote.startsWith('~/') ? remote.substring(2) : remote;
      await c.ssh.upload(s, source.localPath, sftpPath);
    }
    c._log(step, '[link_extras] installed ${source.basename}');
  }
}

Future<void> _runTargetDirLinkExtras(
  WizardController c,
  Map<String, dynamic> step,
  List<String> sources,
) async {
  final s = c._requireSession();
  final rawTargetDir = _stringValue(step['target_dir']);
  if (rawTargetDir == null || rawTargetDir.trim().isEmpty) {
    throw StepExecutionException('link_extras target_dir missing');
  }
  final targetDir = c._render(rawTargetDir.trim());
  c._validateRemoteInstallPath(targetDir, 'link_extras target_dir');
  final method = _stringValue(step['method']) ?? 'copy';
  if (!const {
    'copy',
    'copy_with_backup',
    'copy_with_mode_0755',
  }.contains(method)) {
    throw StepExecutionException('unsupported link_extras method "$method"');
  }
  final resolvedSources = await _resolveLinkExtraSources(c, sources);

  final qTargetDir = shellPathEscape(targetDir);
  final mk = await c._runSsh('mkdir -p -- $qTargetDir');
  if (!mk.success) {
    throw StepExecutionException('remote mkdir failed', stderr: mk.stderr);
  }

  for (final source in resolvedSources) {
    final remote = _joinRemoteDir(targetDir, source.basename);
    if (source.isDirectory) {
      if (method == 'copy_with_backup') {
        await _backupRemoteIfPresent(c, remote);
      }
      await c._uploadDir(source.localPath, remote);
    } else {
      await _uploadLinkExtraFile(c, s, source.localPath, remote, method, step);
    }
    c._log(step, '[link_extras] installed ${source.basename}');
  }
}

Future<List<({String localPath, String basename, bool isDirectory})>>
_resolveLinkExtraSources(WizardController c, List<String> sources) async {
  final resolved = <({String localPath, String basename, bool isDirectory})>[];
  for (final src in sources) {
    final localPath = c._resolveBundledProfileAssetPath(src);
    final rawBasename = p.basename(localPath);
    final basename = c._safeRemoteBasename(rawBasename, 'link_extras source');
    final isDirectory = await Directory(localPath).exists();
    if (isDirectory && basename != rawBasename) {
      throw StepExecutionException(
        'link_extras directory source "$rawBasename" must already use '
        'a safe file name',
      );
    }
    resolved.add((
      localPath: localPath,
      basename: basename,
      isDirectory: isDirectory,
    ));
  }
  return resolved;
}

Future<void> _uploadLinkExtraFile(
  WizardController c,
  SshSession s,
  String localPath,
  String remote,
  String method,
  Map<String, dynamic> step,
) async {
  final mode = _linkExtrasMode(step, method);
  if (method == 'copy') {
    await c.ssh.upload(s, localPath, _sftpPath(remote), mode: mode);
    return;
  }

  final basename = c._safeRemoteBasename(
    p.basename(localPath),
    'link_extras source',
  );
  final tmpRemote =
      '/tmp/deckhand-link-${DateTime.now().microsecondsSinceEpoch}-'
      '${c._randomSuffix()}-$basename';
  await c.ssh.upload(s, localPath, tmpRemote, mode: mode);
  final installMode = _linkExtrasInstallMode(mode);
  final qTmp = shellSingleQuote(tmpRemote);
  final qRemote = shellPathEscape(remote);
  final backup = method == 'copy_with_backup'
      ? 'if [ -e $qRemote ] || [ -L $qRemote ]; then '
            'cp -a -- $qRemote '
            '${shellPathEscape(_backupPathForRemote(c, remote))}; fi && '
      : '';
  try {
    final res = await c._runSsh(
      '${backup}install -m $installMode -- $qTmp $qRemote && rm -f -- $qTmp',
    );
    if (!res.success) {
      throw StepExecutionException('remote install failed', stderr: res.stderr);
    }
  } finally {
    try {
      await c._runSsh('rm -f -- $qTmp');
    } catch (_) {
      // Preserve the original install/backup failure. A leaked temp path
      // is less actionable than hiding why the install failed.
    }
  }
}

Future<void> _backupRemoteIfPresent(WizardController c, String remote) async {
  final qRemote = shellPathEscape(remote);
  final qBackup = shellPathEscape(_backupPathForRemote(c, remote));
  final res = await c._runSsh(
    'if [ -e $qRemote ] || [ -L $qRemote ]; then '
    'cp -a -- $qRemote $qBackup; fi',
  );
  if (!res.success) {
    throw StepExecutionException('remote backup failed', stderr: res.stderr);
  }
}

String _joinRemoteDir(String dir, String basename) {
  final trimmed = dir.trim();
  final separator = trimmed.endsWith('/') ? '' : '/';
  return '$trimmed$separator$basename';
}

String _sftpPath(String remote) =>
    remote.startsWith('~/') ? remote.substring(2) : remote;

String _backupPathForRemote(WizardController c, String remote) {
  final profileId = c._safeRemoteBasename(
    c._profile?.id ?? 'profile',
    'profile id',
  );
  final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(
    RegExp(r'[^0-9A-Za-z]'),
    '',
  );
  return '$remote.deckhand-pre-$profileId-$stamp';
}

int? _linkExtrasMode(Map<String, dynamic> step, String method) {
  final raw = step['mode'];
  final parsed = _parseFileModeImpl(raw);
  if (parsed != null) return parsed;
  if (method == 'copy_with_mode_0755') return int.parse('0755', radix: 8);
  return null;
}

String _linkExtrasInstallMode(int? mode) =>
    (mode ?? int.parse('0644', radix: 8)).toRadixString(8).padLeft(4, '0');

Future<void> _runInstallStackImpl(
  WizardController c,
  Map<String, dynamic> step,
) async {
  c._requireSession();
  final rawComponents = _stringList(step['components']);
  // Expand the `{{stack.webui.selected}}` token into the user's actual
  // webui choices. The profile's `components: [moonraker,
  // "{{stack.webui.selected}}", kiauh, crowsnest]` expects this slot
  // to carry the user's pick(s) — one entry when they picked one
  // (fluidd or mainsail), zero entries when they picked "Neither",
  // multiple when they picked Both. The general `_render` engine
  // can't fan one token into many list entries, so the expansion
  // happens here.
  final webuiSelected = _stringList(c._state.decisions['webui']);
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
    final repo = _stringValue(cfg['repo']);
    final ref = _stringValue(cfg['ref']) ?? 'master';
    final install = _stringValue(cfg['install_path']);
    final releaseRepo = _stringValue(cfg['release_repo']);
    final assetPattern = _stringValue(cfg['asset_pattern']);
    final assetSha256 = _stringValue(cfg['sha256']);
    final rawReleaseTag =
        _stringValue(cfg['tag']) ?? _stringValue(cfg['release_tag']);
    final releaseTag = rawReleaseTag?.trim();
    final releaseTagOrNull = releaseTag == null || releaseTag.isEmpty
        ? null
        : releaseTag;

    if (repo != null && install != null) {
      _validateHttpsGitRepoImpl(repo, '$name repo');
      _validateGitRefImpl(ref, '$name ref');
      c._validateRemoteInstallPath(install, '$name install path');
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
      c._validateRemoteInstallPath(install, '$name install path');
      if (assetSha256 == null || assetSha256.trim().isEmpty) {
        throw StepExecutionException(
          '$name release asset is missing required sha256',
        );
      }
      if (releaseTagOrNull != null) {
        _validateGitRefImpl(releaseTagOrNull, '$name release tag');
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
        tag: releaseTagOrNull,
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
    } else {
      throw StepExecutionException(
        '$name stack component missing install source metadata',
      );
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
        _stringValue(c._state.decisions['service.${svc.id}']) ??
        svc.defaultAction;
    final unit = _stringValue(svc.raw['systemd_unit']);
    final proc = _stringValue(svc.raw['process_pattern']);
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
        _stringValue(c._state.decisions['file.${f.id}']) ?? f.defaultAction;
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
