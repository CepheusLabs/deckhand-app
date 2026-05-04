import 'package:deckhand/main.dart' as app;
import 'package:deckhand_core/deckhand_core.dart';
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
}
