import 'dart:io';

import 'package:deckhand/main.dart' as app;
import 'package:deckhand_core/deckhand_core.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_test/flutter_test.dart';

// Deckhand's detailed widget coverage lives in the individual packages under
// packages/*/test. App-level tests cover startup wiring and release gates.
void main() {
  test('release builds fail closed with placeholder profile trust keyring', () {
    expect(app.profileTrustKeyringAssetPath, 'app/assets/keyring.asc');
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

  test('local smoke release does not enforce production profile trust', () {
    expect(
      app.isProductionTrustEnforcedBuild(
        isReleaseBuild: true,
        isLocalSmokeRelease: false,
      ),
      isTrue,
    );
    expect(
      app.isProductionTrustEnforcedBuild(
        isReleaseBuild: true,
        isLocalSmokeRelease: true,
      ),
      isFalse,
    );
    expect(
      app.isProductionTrustEnforcedBuild(
        isReleaseBuild: false,
        isLocalSmokeRelease: false,
      ),
      isFalse,
    );
  });

  test('startup locale parsing ignores invalid persisted values', () {
    expect(app.parsePreferredLocaleOverride(null), isNull);
    expect(app.parsePreferredLocaleOverride('  '), isNull);
    expect(app.parsePreferredLocaleOverride('not-a-locale'), isNull);
    expect(app.parsePreferredLocaleOverride('en'), isNotNull);
    expect(app.parsePreferredLocaleOverride('es-MX'), isNotNull);
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
      metadata: const {'build_mode': 'test'},
    );

    final logFile = File(p.join(tempDir.path, 'startup_crash.log'));
    final contents = await logFile.readAsString();
    expect(contents, contains('test phase'));
    expect(contents, contains('Bad state: boom'));
    expect(contents, contains('build_mode: test'));
  });
}
