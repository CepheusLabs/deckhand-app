// Backup management for WizardController split out to keep the main
// controller file under a manageable page count. These are top-level
// private helpers that take the controller as their first argument;
// because this file is `part of 'wizard_controller.dart'` they share
// the controller's library-private scope and can read _session, call
// _shellQuote, emit via _emit, etc. without a broader public surface.
part of 'wizard_controller.dart';

Future<void> _restoreBackupImpl(
  WizardController c,
  DeckhandBackup backup,
) async {
  final s = c._requireSession();
  final useSudo = c._looksLikeSystemPath(s, backup.originalPath);
  final qSrc = c._shellQuote(backup.backupPath);
  final qDst = c._shellQuote(backup.originalPath);
  // cp -p preserves mode+owner+timestamps. We chain a `chown --
  // reference` as belt-and-suspenders when running under sudo:
  // if the backup's metadata was somehow flattened to root-owned
  // (shouldn't happen because cp -p preserves), this explicitly
  // copies ownership off the backup file. Silently continues when
  // chown fails (e.g. chown not in PATH on busybox).
  final cp = useSudo ? 'sudo cp -p --' : 'cp -p --';
  final fixOwn = useSudo
      ? ' && sudo chown --reference=$qSrc -- $qDst 2>/dev/null || true'
      : '';
  final cmd = '$cp $qSrc $qDst$fixOwn';
  final res = await c._runSsh(cmd);
  if (!res.success) {
    throw StepExecutionException(
      'Could not restore ${backup.originalPath} from '
      '${backup.backupPath}',
      stderr: res.stderr,
    );
  }
  await c._refreshPrinterState(force: true);
}

Future<String?> _readBackupContentImpl(
  WizardController c,
  DeckhandBackup backup,
) async {
  c._requireSession();
  const maxBytes = 256 * 1024;
  const maxLines = 200;
  final useSudo = c._looksLikeSystemPath(c._session!, backup.backupPath);
  final q = c._shellQuote(backup.backupPath);
  // Binary detection is layered so it works across every shell we
  // care about:
  //   Layer A - `file -b --mime`: full-fat file(1) on Debian /
  //             Armbian / most BSDs. Look for both `charset=binary`
  //             (classic text/plain-vs-binary signal) AND
  //             `application/` types that we know are binary
  //             (octet-stream, zip, x-executable, gzip, ...).
  //   Layer B - `file -b` without --mime: busybox file applet
  //             doesn't have --mime. Falls back to keyword sniff on
  //             the legacy human-readable line (ELF, "data",
  //             "executable", "archive", ...).
  //   Layer C - null-byte count in the first 512 bytes: belt-and-
  //             suspenders for distros without file(1) at all
  //             (stripped Alpine). Uses `od -An -c -N 512` and
  //             greps for the literal `\0` glyph od emits.
  // Any layer that fires short-circuits to the binary marker.
  final fileCmd = useSudo ? 'sudo file -b --mime' : 'file -b --mime';
  final fileBareCmd = useSudo ? 'sudo file -b' : 'file -b';
  final odCmd = useSudo ? 'sudo od -An -c -N 512' : 'od -An -c -N 512';
  final detectCmd =
      '($fileCmd $q 2>/dev/null) || '
      '($fileBareCmd $q 2>/dev/null) || '
      '($odCmd $q 2>/dev/null)';
  final probe = await c._runSsh(detectCmd);
  if (WizardController.looksLikeBinary(probe.stdout)) {
    return '[binary file, ${backup.backupPath.split('/').last} - '
        'preview unavailable]';
  }
  // Text read with byte cap; pipe through head -n for line cap.
  final head = useSudo ? 'sudo head -c $maxBytes' : 'head -c $maxBytes';
  final res = await c._runSsh('$head $q 2>/dev/null || true');
  if (res.stdout.isEmpty) return null;
  var body = res.stdout;
  final bytesTruncated = body.length >= maxBytes;
  final lines = body.split('\n');
  var linesTruncated = false;
  if (lines.length > maxLines) {
    body = lines.take(maxLines).join('\n');
    linesTruncated = true;
  }
  final notes = <String>[
    if (bytesTruncated) 'truncated at 256 KiB',
    if (linesTruncated)
      'truncated at $maxLines lines (file has ${lines.length} lines total)',
  ];
  if (notes.isEmpty) return body;
  return '$body\n\n[... ${notes.join("; ")} ...]';
}

Future<void> _deleteBackupImpl(
  WizardController c,
  DeckhandBackup backup,
) async {
  c._requireSession();
  final useSudo = c._looksLikeSystemPath(c._session!, backup.backupPath);
  final rm = useSudo ? 'sudo rm -f --' : 'rm -f --';
  final qBackup = c._shellQuote(backup.backupPath);
  final qMeta = c._shellQuote('${backup.backupPath}.meta.json');
  final res = await c._runSsh('$rm $qBackup $qMeta');
  if (!res.success) {
    throw StepExecutionException(
      'Could not delete backup ${backup.backupPath}',
      stderr: res.stderr,
    );
  }
  await c._refreshPrinterState(force: true);
}

Future<int> _pruneBackupsImpl(
  WizardController c, {
  Duration olderThan = const Duration(days: 30),
  bool keepLatestPerTarget = false,
}) async {
  c._requireSession();
  final cutoff = DateTime.now().subtract(olderThan);
  var victims = c._printerState.deckhandBackups.where((b) {
    final age = b.createdAt;
    if (age == null) return false;
    return age.isBefore(cutoff);
  }).toList();
  if (keepLatestPerTarget) {
    // Build {originalPath -> newest backup} across the FULL backup
    // list, then exclude those from the victim set regardless of
    // age. Caller opts in when they want a safety-net keep policy.
    final newest = <String, DeckhandBackup>{};
    for (final b in c._printerState.deckhandBackups) {
      final t = b.createdAt?.millisecondsSinceEpoch ?? 0;
      final current = newest[b.originalPath];
      if (current == null ||
          (current.createdAt?.millisecondsSinceEpoch ?? 0) < t) {
        newest[b.originalPath] = b;
      }
    }
    final spared = newest.values.map((b) => b.backupPath).toSet();
    victims = victims.where((b) => !spared.contains(b.backupPath)).toList();
  }
  if (victims.isEmpty) return 0;
  // Split into sudo-required and plain batches so we don't escalate
  // when we don't need to (and don't fail when sudo is required).
  final sudoBatch = <String>[];
  final plainBatch = <String>[];
  for (final b in victims) {
    final paths = [
      c._shellQuote(b.backupPath),
      c._shellQuote('${b.backupPath}.meta.json'),
    ];
    if (c._looksLikeSystemPath(c._session!, b.backupPath)) {
      sudoBatch.addAll(paths);
    } else {
      plainBatch.addAll(paths);
    }
  }
  if (plainBatch.isNotEmpty) {
    final res = await c._runSsh('rm -f -- ${plainBatch.join(" ")}');
    if (!res.success) {
      throw StepExecutionException(
        'Could not prune user-owned backups',
        stderr: res.stderr,
      );
    }
  }
  if (sudoBatch.isNotEmpty) {
    final res = await c._runSsh('sudo rm -f -- ${sudoBatch.join(" ")}');
    if (!res.success) {
      throw StepExecutionException(
        'Could not prune root-owned backups',
        stderr: res.stderr,
      );
    }
  }
  await c._refreshPrinterState(force: true);
  return victims.length;
}
