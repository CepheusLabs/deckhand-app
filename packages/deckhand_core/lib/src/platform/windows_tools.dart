import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// Returns the trusted Windows PowerShell 5.1 executable path.
///
/// Deckhand uses PowerShell for Windows shell integration only. Security-
/// sensitive flows must not resolve `powershell.exe` through PATH because a
/// writable PATH entry could hijack disk operations or diagnostics.
String trustedWindowsPowerShellExecutable() {
  if (!Platform.isWindows) return 'powershell.exe';
  return resolveTrustedWindowsPowerShellExecutable(
    environment: Platform.environment,
    exists: (path) => File(path).existsSync(),
  );
}

String resolveTrustedWindowsPowerShellExecutable({
  required Map<String, String> environment,
  required bool Function(String path) exists,
}) {
  const defaultWindowsRoot = r'C:\Windows';
  final roots = <String>[
    defaultWindowsRoot,
    environment['SystemRoot'] ?? '',
    environment['WINDIR'] ?? '',
  ];
  final seen = <String>{};
  for (final rawRoot in roots) {
    final root = rawRoot.trim();
    if (root.isEmpty || !seen.add(root.toLowerCase())) continue;
    final candidate = windowsPowerShellPathUnder(root);
    if (exists(candidate)) return candidate;
  }
  return windowsPowerShellPathUnder(defaultWindowsRoot);
}

@visibleForTesting
String windowsPowerShellPathUnder(String windowsRoot) => p.Context(
  style: p.Style.windows,
).join(windowsRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
