import 'dart:io';

import 'package:deckhand/main.dart' as app;
import 'package:deckhand_core/deckhand_core.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_test/flutter_test.dart';

// Deckhand's widget tests live in the individual packages under
// packages/*/test. This file is intentionally minimal so `flutter test`
// has something to run.
void main() {
  test('placeholder', () {
    expect(1 + 1, 2);
  });

  test('release builds fail closed with placeholder profile trust keyring', () {
    expect(
      () => app.enforceProfileTrustKeyringForBuild(
        isReleaseBuild: true,
        trustKeyring: TrustKeyring.forTest(
          armored: 'placeholder',
          isPlaceholder: true,
        ),
      ),
      throwsStateError,
    );
    expect(
      () => app.enforceProfileTrustKeyringForBuild(
        isReleaseBuild: false,
        trustKeyring: TrustKeyring.forTest(
          armored: 'placeholder',
          isPlaceholder: true,
        ),
      ),
      returnsNormally,
    );
  });

  test('startup failures are written to the startup crash log', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'deckhand_startup_test_',
    );
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    await app.writeStartupFailureLog(
      logsDir: tempDir.path,
      phase: 'test phase',
      error: StateError('boom'),
      stackTrace: StackTrace.current,
    );

    final logFile = File(p.join(tempDir.path, 'startup_crash.log'));
    final contents = await logFile.readAsString();
    expect(contents, contains('test phase'));
    expect(contents, contains('Bad state: boom'));
  });
}
