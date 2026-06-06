// CLI entry. Walks a deckhand-profiles checkout, parses every
// printers/<id>/profile.yaml, validates against the shipped schema,
// cross-references registry.yaml, and reports violations.
//
// Exits 0 on success, 1 on any lint failure, 2 on a usage/IO error.
// --strict treats warnings (stub status, missing optional metadata) as
// failures too so CI can gate release tags.
import 'dart:io';

import 'package:deckhand_profile_lint/deckhand_profile_lint.dart';

Future<void> main(List<String> argv) async {
  try {
    final report = await runProfileLint(argv);
    report.writeTo(stdout);
    exit(report.hasErrors ? 1 : 0);
  } on LintUsageException catch (e) {
    stderr.writeln('deckhand-profile-lint: ${e.message}');
    exit(2);
  } on FileSystemException catch (e) {
    stderr.writeln('deckhand-profile-lint: ${e.message}: ${e.path}');
    exit(2);
  }
}
