final _physicalDriveRe = RegExp(
  r'(?:\\\\\.\\)?PHYSICALDRIVE(\d+)|PhysicalDrive(\d+)',
  caseSensitive: false,
);

String userFacingDiskOperationError(Object? error) {
  final message = _stripExceptionPrefixes(
    (error ?? 'Unknown error').toString().trim(),
  );
  final lower = message.toLowerCase();
  if (lower.contains('elevated helper never started')) {
    return 'Windows did not start Deckhand\'s disk helper. Deckhand cannot write raw disks until that helper launches with administrator rights. Start Deckhand as Administrator, then retry.';
  }
  if (lower.contains('elevated helper is not configured')) {
    return 'This Deckhand build is missing the elevated disk helper. Rebuild or reinstall the Windows release bundle, then retry.';
  }
  if (lower.contains('lock volume') && lower.contains('access is denied')) {
    return 'Windows would not release the selected disk. Close File Explorer, Disk Management, terminals, and any app using that USB drive, then unplug/replug the adapter and retry.';
  }
  if (lower.contains('access is denied') && lower.contains('physicaldrive')) {
    final disk = _friendlyDiskName(message) ?? 'the selected disk';
    return 'Windows denied raw-disk access to $disk. Start Deckhand as Administrator, close anything using the USB drive, then retry.';
  }
  if (lower.contains('parameter is incorrect') &&
      lower.contains('physicaldrive')) {
    final disk = _friendlyDiskName(message) ?? 'the selected disk';
    return 'Windows rejected the raw disk write to $disk. Replug the USB adapter and retry; if it repeats, use a different eMMC reader or adapter.';
  }
  if (lower.contains('confirmation token was rejected')) {
    return 'Deckhand rejected the restore authorization token before launching the disk helper. Restart Deckhand and retry.';
  }
  return hideRawDiskIds(message);
}

String hideRawDiskIds(String message) {
  return message.replaceAllMapped(_physicalDriveRe, (match) {
    final number = match.group(1) ?? match.group(2) ?? '';
    return 'Windows disk $number';
  });
}

String _stripExceptionPrefixes(String message) {
  var remaining = message.trim();
  var changed = true;
  while (changed) {
    changed = false;
    for (final prefix in const [
      'Exception: ',
      'StateError: ',
      'StepExecutionException: ',
      'ElevatedHelperException: ',
    ]) {
      if (remaining.startsWith(prefix)) {
        remaining = remaining.substring(prefix.length).trim();
        changed = true;
      }
    }
  }
  return remaining;
}

String? _friendlyDiskName(String message) {
  final match = _physicalDriveRe.firstMatch(message);
  if (match == null) return null;
  final number = match.group(1) ?? match.group(2);
  if (number == null) return null;
  return 'Windows disk $number';
}
