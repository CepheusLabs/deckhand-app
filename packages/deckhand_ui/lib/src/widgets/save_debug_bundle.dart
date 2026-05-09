import 'dart:async';
import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../providers.dart';
import '../utils/user_facing_errors.dart';

/// Riverpod hook that turns the [DebugBundleScreen]'s `onSave`
/// callback into an actual zip on disk via [BundleBuilder].
///
/// The screen is UI-only by design: it shows the redacted preview
/// and emits a [RedactedDocument] when the user clicks Save. This
/// helper composes it with the wizard's known state to produce a
/// zip in `<data_dir>/debug-bundles/`.
///
/// Returns the [BundleResult] (path + sha256 + aggregate stats)
/// when the user proceeds; null when they cancelled. Errors during
/// the actual zip-write are caught here and surfaced as a snackbar
/// — the user has already approved the redacted contents, a
/// disk-write failure shouldn't crash the route.
Future<BundleResult?> saveDebugBundle({
  required BuildContext context,
  required WidgetRef ref,
  required RedactedDocument redactedLog,
  required HostInfoSnapshot host,
  Map<String, String>? extraTextFiles,
}) async {
  final controller = ref.read(wizardControllerProvider);
  final bundlesDir = ref.read(debugBundlesDirProvider);
  if (bundlesDir == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Debug bundles are not configured (no bundlesDir provider). '
          'The redacted log was kept in memory but not written.',
        ),
      ),
    );
    return null;
  }

  final wizardState = controller.state;
  await Directory(bundlesDir).create(recursive: true);
  final outPath = p.join(bundlesDir, defaultBundleName());

  // Re-derive the same redactor the screen used so the manifest's
  // placeholder hashes round-trip cleanly.
  final redactor = Redactor(sessionValues: controller.redactionSessionValues());

  try {
    final builder = BundleBuilder(outputPath: outPath, redactor: redactor);
    final result = await builder.build(
      sessionLog: redactedLog,
      wizardState: wizardState,
      host: host,
      extraTextFiles: extraTextFiles,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Saved ${p.basename(result.path)} '
            '(sha256 ${result.sha256.substring(0, 12)}…)',
          ),
        ),
      );
    }
    return result;
  } on Object catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Bundle write failed: ${userFacingError(e)}')),
      );
    }
    return null;
  }
}
