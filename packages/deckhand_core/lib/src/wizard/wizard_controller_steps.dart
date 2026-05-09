// Large step-execution bodies split out of wizard_controller.dart to
// keep the main controller file under a reasonable page count. All of
// these are top-level private helpers that take the controller as
// their first argument; they share WizardController's library-private
// scope because this file is `part of 'wizard_controller.dart'`.
part of 'wizard_controller.dart';

Future<void> _runWriteFileImpl(
  WizardController c,
  Map<String, dynamic> step,
) async {
  final s = c._requireSession();
  final target = _stringValue(step['target']);
  final templatePath = _stringValue(step['template']);
  final content = _stringValue(step['content']);
  if (target == null) {
    throw StepExecutionException('write_file missing target');
  }
  // Per-step precondition: only run when `require_path` exists on
  // the printer. Lets a profile gate destructive writes on runtime
  // state (e.g. "only rewrite KlipperScreen's launcher if
  // KlipperScreen is actually installed"). Cheaper than wrapping
  // every caller in a conditional.
  final requirePath = _stringValue(step['require_path']);
  if (requirePath != null) {
    final qReq = c._shellQuote(requirePath);
    final check = await c.ssh.run(s, '[ -e $qReq ] && echo y || echo n');
    if (!check.stdout.contains('y')) {
      c._log(
        step,
        '[write_file] skipped: require_path "$requirePath" does not '
        'exist on this printer',
      );
      return;
    }
  }
  String rendered;
  if (content != null) {
    rendered = c._render(content);
  } else if (templatePath != null) {
    final src = c._resolveProfilePath(templatePath);
    rendered = c._render(await File(src).readAsString());
  } else {
    throw StepExecutionException('write_file requires template or content');
  }

  // Explicit `sudo: true` wins; otherwise default to sudo for paths
  // outside the SSH user's home directory. We can't SFTP directly to
  // root-owned paths like /etc/apt/sources.list, so stage in /tmp
  // and mv into place.
  final useSudo = step['sudo'] is bool
      ? step['sudo'] as bool
      : c._looksLikeSystemPath(s, target);
  final mode = _parseFileModeImpl(step['mode']);
  final owner = _stringValue(step['owner']);
  // Auto-snapshot the existing file before overwriting, unless the
  // step explicitly opts out (backup: false).
  final backup = step['backup'] is bool ? step['backup'] as bool : true;

  final ts = DateTime.now().millisecondsSinceEpoch;
  final suffix = c._randomSuffix();
  final tmpLocal = p.join(Directory.systemTemp.path, 'deckhand-$suffix.tmp');
  final remoteTmp = '/tmp/deckhand-write-$suffix.tmp';
  await File(tmpLocal).writeAsString(rendered);

  try {
    if (backup) {
      final qTarget0 = c._shellQuote(target);
      final profileTag = c._profile?.id ?? 'unknown';
      final backupPath = '$target.deckhand-pre-$profileTag-$ts';
      final metadataPath = '$backupPath.meta.json';
      final qBackup = c._shellQuote(backupPath);
      final qMeta = c._shellQuote(metadataPath);
      final meta = const JsonEncoder.withIndent('  ').convert({
        'profile_id': c._profile?.id,
        'profile_version': c._profile?.version,
        'step_id': step['id'],
        'backup_of': target,
        'created_at_ms': ts,
        'created_at_iso': DateTime.now().toUtc().toIso8601String(),
        'deckhand_schema': 1,
      });
      // Stage the metadata locally and SFTP-upload it to a temp
      // path, then mv into place. The earlier inline
      // `sh -c "printf %s ... > ..."` trick layered a single-quoted
      // JSON payload inside a double-quoted sh -c argument, which
      // becomes fragile the moment `qMeta` contains a double quote
      // (possible when the target path has one). SFTP + sudo-mv is
      // the same number of round trips and has no nested-quoting
      // surface at all.
      final metaTmpLocal = p.join(
        Directory.systemTemp.path,
        'deckhand-meta-$suffix.json',
      );
      await File(metaTmpLocal).writeAsString(meta);
      final remoteMetaTmp = '/tmp/deckhand-meta-$suffix.json';
      await c.ssh.upload(s, metaTmpLocal, remoteMetaTmp, mode: 420); // 0o644
      final cp = useSudo ? 'sudo cp -p --' : 'cp -p --';
      final writeMeta = useSudo
          ? 'sudo mv -- $remoteMetaTmp $qMeta && sudo chmod 0644 -- $qMeta'
          : 'mv -- $remoteMetaTmp $qMeta';
      final writeProbe = useSudo
          ? 'sudo touch -- "\$(dirname $qTarget0)/.deckhand-wtest-$ts" '
                '2>/dev/null && '
                'sudo rm -f -- "\$(dirname $qTarget0)/.deckhand-wtest-$ts"'
          : 'touch -- "\$(dirname $qTarget0)/.deckhand-wtest-$ts" '
                '2>/dev/null && '
                'rm -f -- "\$(dirname $qTarget0)/.deckhand-wtest-$ts"';
      final snapCmd =
          'if [ ! -e $qTarget0 ]; then echo DECKHAND_BACKUP_NOOP; '
          'elif ! ( $writeProbe ); then '
          '  echo DECKHAND_BACKUP_RO_FS; '
          'else '
          '  $cp $qTarget0 $qBackup && $writeMeta && '
          '  echo DECKHAND_BACKUP_CREATED; '
          'fi';
      final snapRes = await c._runSsh(snapCmd);
      if (!snapRes.success) {
        c._emit(
          StepWarning(
            stepId: _stringValue(step['id']) ?? 'write_file',
            message:
                'Could not snapshot existing $target before '
                'overwrite: ${snapRes.stderr.trim()}',
          ),
        );
      } else if (snapRes.stdout.contains('DECKHAND_BACKUP_CREATED')) {
        c._log(step, '[write_file] backup -> $backupPath');
      } else if (snapRes.stdout.contains('DECKHAND_BACKUP_RO_FS')) {
        c._emit(
          StepWarning(
            stepId: _stringValue(step['id']) ?? 'write_file',
            message:
                'Target filesystem is read-only; no backup taken. The '
                'write step below may still succeed under sudo, but '
                'you will have no rollback snapshot.',
          ),
        );
      } else {
        c._log(step, '[write_file] no prior $target; nothing to back up');
      }
    }
    await c.ssh.upload(s, tmpLocal, remoteTmp);
    final qTmp = c._shellQuote(remoteTmp);
    final qTarget = c._shellQuote(target);
    final modeArg = mode != null ? '-m ${mode.toRadixString(8)} ' : '';
    final ownerArg = owner != null ? '-o ${c._shellQuote(owner)} ' : '';
    final String cmd;
    if (useSudo) {
      cmd = 'sudo install $modeArg$ownerArg-- $qTmp $qTarget && rm -f -- $qTmp';
    } else {
      final chmod = mode != null
          ? ' && chmod ${mode.toRadixString(8)} -- $qTarget'
          : '';
      cmd = 'mv -- $qTmp $qTarget$chmod';
    }
    final res = await c._runSsh(cmd);
    c._log(
      step,
      '[write_file] wrote $target (${rendered.length} bytes'
      '${useSudo ? ', via sudo' : ''})',
    );
    if (!res.success) {
      await c._runSsh('rm -f -- $qTmp');
      throw StepExecutionException(
        'write_file $target failed',
        stderr: res.stderr,
      );
    }
  } finally {
    try {
      await File(tmpLocal).delete();
    } catch (_) {}
    try {
      final metaTmpLocal = p.join(
        Directory.systemTemp.path,
        'deckhand-meta-$suffix.json',
      );
      final f = File(metaTmpLocal);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

/// Accepts an int (already decimal) or a string like `"0644"` / `"755"`
/// / `"0o755"` and returns the integer mode. Returns null when the
/// step omits `mode:`.
int? _parseFileModeImpl(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) {
    var raw = v.trim();
    if (raw.startsWith('0o') || raw.startsWith('0O')) {
      raw = raw.substring(2);
    }
    try {
      return int.parse(raw, radix: 8);
    } on FormatException {
      // Surface profile YAML mistakes ("nine", "0o999", "0xFF") as
      // a clean step error rather than letting a raw FormatException
      // bubble through with a Dart stack trace.
      throw StepExecutionException(
        'invalid mode "$v": expected an integer or octal string '
        '(e.g. 0644, "755", "0o600")',
      );
    }
  }
  return null;
}

Future<void> _runInstallScreenImpl(
  WizardController c,
  Map<String, dynamic> step,
) async {
  final s = c._requireSession();
  final screenId = _stringValue(c._state.decisions['screen']);
  if (screenId == null) {
    c._log(step, '[screen] no screen selected - skipping install');
    return;
  }
  final screen = c._profile!.screens.firstWhere(
    (sc) => sc.id == screenId,
    orElse: () => throw StepExecutionException('unknown screen $screenId'),
  );
  final sourceKind = _stringValue(screen.raw['source_kind']);
  if (sourceKind == null || sourceKind == 'bundled') {
    final sourcePath = _stringValue(screen.raw['source_path']);
    if (sourcePath == null || sourcePath.trim().isEmpty) {
      throw StepExecutionException(
        'screen $screenId bundled source must declare source_path',
      );
    }
    final src = c._resolveBundledProfileAssetPath(sourcePath);
    final remote = '~/${p.basename(src)}';
    await c._uploadDir(src, remote);
    final installScript = _stringValue(screen.raw['install_script']);
    if (installScript != null && installScript.trim().isNotEmpty) {
      final srcInstall = c._resolveBundledProfileAssetPath(installScript);
      const remoteInstall = '~/deckhand-screen-install.sh';
      await c.ssh.upload(s, srcInstall, remoteInstall, mode: 493); // 0o755
      final res = await c._runSsh(
        'bash $remoteInstall',
        timeout: const Duration(minutes: 5),
      );
      if (!res.success) {
        throw StepExecutionException(
          'screen install script failed',
          stderr: res.stderr,
        );
      }
    }
    c._log(step, '[screen] installed $screenId');
  } else if (sourceKind == 'stock_in_place' ||
      sourceKind == 'hardware_optional') {
    c._log(
      step,
      '[screen] $screenId already handled by the printer - skipping',
    );
  } else if (sourceKind == 'restore_from_backup') {
    throw StepExecutionException(
      'screen $screenId restore-from-backup is not implemented',
    );
  } else {
    throw StepExecutionException(
      'screen $screenId source kind "$sourceKind" is not implemented',
    );
  }
}

Future<void> _runFlashMcusImpl(
  WizardController c,
  Map<String, dynamic> step,
) async {
  throw StepExecutionException(
    'mcu flashing is not implemented by Deckhand yet',
  );
}

Future<void> _runOsDownloadImpl(
  WizardController c,
  Map<String, dynamic> step,
) async {
  final osId = c._state.decisions['flash.os'] as String?;
  if (osId == null) throw StepExecutionException('no OS image selected');
  final opt = c._profile!.os.freshInstallOptions.firstWhere(
    (o) => o.id == osId,
    orElse: () => throw StepExecutionException('unknown OS option $osId'),
  );
  final imageUrl = Uri.tryParse(opt.url);
  if (imageUrl == null || imageUrl.scheme != 'https' || imageUrl.host.isEmpty) {
    throw StepExecutionException('OS image "$osId" must use an https:// URL');
  }
  final expectedSha = opt.sha256?.trim().toLowerCase();
  if (expectedSha == null || !_isSha256HexImpl(expectedSha)) {
    throw StepExecutionException(
      'OS image "$osId" must declare a 64-hex sha256 before download',
    );
  }
  final defaultOsImageDir =
      c.osImagesDir ?? p.join(Directory.systemTemp.path, 'deckhand-os-images');
  final dest =
      step['dest'] as String? ??
      p.join(defaultOsImageDir, '${_safeOsImageCacheIdImpl(opt.id)}.img');
  c._log(step, '[os] preparing ${opt.url} -> $dest');

  final stepId = step['id'] as String? ?? 'os_download';
  String? sha;
  var actualPath = dest;
  await for (final ev in c.upstream.osDownload(
    url: opt.url,
    destPath: dest,
    expectedSha256: expectedSha,
  )) {
    if (ev.phase == OsDownloadPhase.done) {
      sha = ev.sha256;
      actualPath = ev.path ?? actualPath;
      if (ev.reused) {
        c._log(step, '[os] using cached image $actualPath');
      }
      c._emit(
        StepProgress(
          stepId: stepId,
          percent: 1.0,
          message: ev.reused ? 'using cached image' : 'download complete',
        ),
      );
    } else if (ev.phase == OsDownloadPhase.failed) {
      throw StepExecutionException('os download failed');
    } else if (ev.phase == OsDownloadPhase.extracting) {
      c._emit(
        StepProgress(
          stepId: stepId,
          percent: ev.bytesTotal > 0 ? ev.fraction : null,
          message:
              'extracting image'
              '${ev.bytesDone > 0 ? ' (${(ev.bytesDone / (1 << 20)).toStringAsFixed(1)} MiB)' : ''}',
        ),
      );
    } else {
      c._emit(
        StepProgress(
          stepId: stepId,
          percent: ev.fraction,
          message:
              '${(ev.bytesDone / (1 << 20)).toStringAsFixed(1)} MiB'
              '${ev.bytesTotal > 0 ? ' / ${(ev.bytesTotal / (1 << 20)).toStringAsFixed(1)} MiB' : ''}',
        ),
      );
    }
  }

  await c.setDecision('flash.image_path', actualPath);
  if (sha != null) {
    await c.setDecision('flash.image_sha256', sha);
  }
  c._log(
    step,
    '[os] ready at $actualPath${sha != null ? " (sha256 $sha)" : ""}',
  );
}

bool _isSha256HexImpl(String value) =>
    RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

String _safeOsImageCacheIdImpl(String value) {
  final safe = value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
      .replaceAll(RegExp(r'^[._-]+|[._-]+$'), '');
  if (safe.isEmpty) {
    throw StepExecutionException('OS image id is not safe for cache file name');
  }
  if (safe.length <= 120) return safe;
  final truncated = safe.substring(0, 120).replaceAll(RegExp(r'[._-]+$'), '');
  return truncated.isEmpty ? 'image' : truncated;
}

Future<void> _runFlashDiskImpl(
  WizardController c,
  Map<String, dynamic> step,
) async {
  final diskId = c._state.decisions['flash.disk'] as String?;
  if (diskId == null) throw StepExecutionException('no flash disk selected');
  final diskName = await _userFacingDiskNameForIdImpl(c, diskId);
  final imagePath = c._state.decisions['flash.image_path'] as String?;
  if (imagePath == null) {
    throw StepExecutionException(
      'no image path recorded - did os_download run?',
    );
  }
  final helper = c.elevatedHelper;
  if (helper == null) {
    throw StepExecutionException(
      'elevated helper not configured - cannot write raw disk',
    );
  }
  final verdict = await c.flash.safetyCheck(diskId: diskId);
  if (!verdict.allowed) {
    final reasons = verdict.blockingReasons.isEmpty
        ? 'no blocking reason returned'
        : verdict.blockingReasons.join('; ');
    throw StepExecutionException(
      'disk safety check refused $diskName: $reasons',
    );
  }
  if (verdict.warnings.isNotEmpty) {
    final acknowledged =
        c._state.decisions['flash.safety_warnings_acknowledged'] == true ||
        c._state.decisions['flash.safety_warnings_acknowledged.$diskId'] ==
            true;
    if (!acknowledged) {
      throw StepExecutionException(
        'disk safety check returned warnings for $diskName: '
        '${verdict.warnings.join('; ')}',
      );
    }
    c._log(
      step,
      '[flash] safety warning acknowledged: ${verdict.warnings.join('; ')}',
    );
  }
  final token = await c.security.issueConfirmationToken(
    operation: 'write_image',
    target: diskId,
  );
  // Mark the token consumed immediately. The UI flow has done its
  // job - a hostile or replayed call to a SecurityService method using
  // the same value now fails, even though the value will live briefly
  // in the helper invocation. This pairs with the elevated helper's
  // --token-file mechanism, which keeps the value off the process
  // table and out of /proc/<pid>/cmdline.
  final consumed = c.security.consumeToken(
    token.value,
    'write_image',
    target: diskId,
  );
  if (!consumed) {
    throw StepExecutionException(
      'confirmation token was rejected before helper launch',
    );
  }
  final verify = step['verify_after_write'] as bool? ?? true;
  final expectedSha = await _resolveExpectedFlashSha256Impl(c);
  final stepId = step['id'] as String? ?? 'flash_disk';
  c._log(step, '[flash] writing $imagePath -> $diskName (verify=$verify)');

  await for (final ev in helper.writeImage(
    imagePath: imagePath,
    diskId: diskId,
    confirmationToken: token.value,
    verifyAfterWrite: verify,
    expectedSha256: expectedSha,
  )) {
    final pct = ev.fraction;
    c._emit(StepProgress(stepId: stepId, percent: pct, message: ev.message));
    if (ev.phase == FlashPhase.failed) {
      throw StepExecutionException(ev.message ?? 'flash failed');
    }
  }
  c._log(step, '[flash] done');
}

Future<String> _resolveExpectedFlashSha256Impl(WizardController c) async {
  final recorded = (c._state.decisions['flash.image_sha256'] as String?)
      ?.trim()
      .toLowerCase();
  if (recorded != null && _isSha256HexImpl(recorded)) {
    if (recorded != c._state.decisions['flash.image_sha256']) {
      await c.setDecision('flash.image_sha256', recorded);
    }
    return recorded;
  }

  final osId = c._state.decisions['flash.os'] as String?;
  if (osId != null) {
    for (final opt
        in c._profile?.os.freshInstallOptions ?? const <OsImageOption>[]) {
      if (opt.id != osId) continue;
      final profileSha = opt.sha256?.trim().toLowerCase();
      if (profileSha != null && _isSha256HexImpl(profileSha)) {
        await c.setDecision('flash.image_sha256', profileSha);
        return profileSha;
      }
    }
  }

  throw StepExecutionException(
    'flash image sha256 is missing or invalid; rerun the OS download step',
  );
}

Future<void> _runScriptImpl(
  WizardController c,
  Map<String, dynamic> step,
) async {
  final s = c._requireSession();
  final rel = _stringValue(step['path']);
  if (rel == null) {
    throw StepExecutionException('script step missing "path"');
  }
  final local = c._resolveProfilePath(rel);
  if (!await File(local).exists()) {
    throw StepExecutionException('script not found: $rel');
  }
  final interpreter = _validatedScriptInterpreterImpl(step['interpreter']);
  // A random suffix makes the remote path unguessable so a non-root
  // attacker on the printer cannot read (or race-overwrite) the
  // staged script while it is still on disk. mode 0o700 - only
  // the SSH user's shell execs it, nobody else reads or mutates.
  final basename = c._safeRemoteBasename(rel, 'script path');
  final remote = '/tmp/deckhand-${c._randomSuffix()}-$basename';
  await c.ssh.upload(s, local, remote, mode: 448); // 0o700
  final extraArgs = _stringList(step['args']);
  final ignoreErrors = _boolValue(step['ignore_errors']);
  final timeoutSecs = _positiveIntValue(step['timeout_seconds'], 600);
  // Two orthogonal knobs, intentionally un-coupled:
  //   - `sudo: true`  -> wrap the whole invocation in `sudo -E`
  //                      so the script runs as root from line 1.
  //   - `askpass`     -> stand up an askpass helper + a PATH-shimmed
  //                      `sudo` wrapper so any *internal* `sudo X`
  //                      the script issues can authenticate without
  //                      a pty. On by default whenever we have a
  //                      cached password (i.e. password SSH). Turn
  //                      off with `askpass: false` for scripts you
  //                      want to prove don't elevate at all.
  final useSudo = _boolValue(step['sudo']);
  final setUpAskpass =
      _boolValueOr(step['askpass'], true) && c._sshPassword != null;

  final argStr = extraArgs.map(shellSingleQuote).join(' ');
  final qRemote = shellSingleQuote(remote);
  final baseCmd = argStr.isEmpty
      ? '$interpreter $qRemote'
      : '$interpreter $qRemote $argStr';

  final extraEnvPrefix = c._buildEnvPrefix(step['env']);

  String envPrefix = extraEnvPrefix;
  _ScriptSudoHelper? helper;
  if (setUpAskpass) {
    helper = await _installSudoAskpassHelperImpl(c);
    envPrefix =
        '${envPrefix}SUDO_ASKPASS=${shellSingleQuote(helper.askpassPath)} '
        'PATH=${shellSingleQuote(helper.binDir)}:\$PATH ';
  }
  final String cmd;
  if (useSudo && setUpAskpass) {
    cmd = '${envPrefix}sudo -A -E $baseCmd';
  } else if (useSudo) {
    cmd = 'sudo -E $baseCmd';
  } else {
    cmd = '$envPrefix$baseCmd';
  }
  c._log(
    step,
    '[script] running $rel'
    '${useSudo ? " (root)" : ""}'
    '${setUpAskpass ? " (askpass)" : ""}',
  );
  try {
    final res = await c._runSsh(cmd, timeout: Duration(seconds: timeoutSecs));
    if (res.stdout.trim().isNotEmpty) {
      for (final line in res.stdout.trim().split('\n')) {
        c._log(step, '[script]   $line');
      }
    }
    if (!res.success && !ignoreErrors) {
      if (_looksLikeSudoPtyErrorImpl(res.stderr)) {
        throw StepExecutionException(
          'script $rel could not authenticate for sudo over an SSH '
          'session without a tty. Check the printer\'s sudoers config: '
          'either grant passwordless sudo for this user, or ensure '
          'SUDO_ASKPASS is permitted (no `Defaults requiretty`, no '
          '`Defaults !visiblepw`).',
          stderr: res.stderr,
        );
      }
      throw StepExecutionException(
        'script $rel failed (exit ${res.exitCode})',
        stderr: res.stderr,
      );
    }
    c._log(step, '[script] done ($rel, exit ${res.exitCode})');
  } finally {
    await c._runSsh('rm -f -- $qRemote');
    if (helper != null) {
      await _cleanupSudoAskpassHelperImpl(c, helper);
    }
  }
}

/// Stages a temporary sudo-askpass helper + `sudo` wrapper on the
/// remote printer.
Future<_ScriptSudoHelper> _installSudoAskpassHelperImpl(
  WizardController c,
) async {
  final s = c._requireSession();
  final pw = c._sshPassword;
  if (pw == null) {
    throw StateError('cannot install askpass helper without a password');
  }
  final ts = DateTime.now().microsecondsSinceEpoch;
  final askpassPath = '/tmp/deckhand-askpass-$ts';
  final binDir = '/tmp/deckhand-bin-$ts';

  final askpassBody = "#!/bin/sh\nprintf '%s' ${c._shellQuote(pw)}\n";
  final askpassLocal = p.join(
    Directory.systemTemp.path,
    'deckhand-askpass-$ts.sh',
  );
  await File(askpassLocal).writeAsString(askpassBody);
  try {
    await c.ssh.upload(s, askpassLocal, askpassPath, mode: 448); // 0o700
  } finally {
    try {
      await File(askpassLocal).delete();
    } catch (_) {}
  }
  await c.ssh.run(s, 'chmod 700 ${c._shellQuote(askpassPath)}');

  const wrapperBody = '#!/bin/sh\nexec /usr/bin/sudo -A "\$@"\n';
  final wrapperLocal = p.join(
    Directory.systemTemp.path,
    'deckhand-sudo-$ts.sh',
  );
  await File(wrapperLocal).writeAsString(wrapperBody);
  try {
    await c.ssh.run(s, 'mkdir -p ${c._shellQuote(binDir)}');
    await c.ssh.upload(s, wrapperLocal, '$binDir/sudo', mode: 493); // 0o755
  } finally {
    try {
      await File(wrapperLocal).delete();
    } catch (_) {}
  }
  await c.ssh.run(s, 'chmod 755 ${c._shellQuote('$binDir/sudo')}');

  final helper = _ScriptSudoHelper(askpassPath: askpassPath, binDir: binDir);
  return helper;
}

Future<void> _cleanupSudoAskpassHelperImpl(
  WizardController c,
  _ScriptSudoHelper helper,
) async {
  try {
    await c._runSsh(
      'rm -rf -- '
      '${shellSingleQuote(helper.askpassPath)} '
      '${shellSingleQuote(helper.binDir)}',
    );
  } catch (_) {}
  if (identical(c._sessionAskpass, helper)) {
    c._sessionAskpass = null;
  }
}

bool _looksLikeSudoPtyErrorImpl(String stderr) {
  final lower = stderr.toLowerCase();
  return lower.contains('a terminal is required') ||
      lower.contains('no tty present') ||
      lower.contains('askpass helper') ||
      lower.contains('a password is required');
}
