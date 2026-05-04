/// Build-time constants threaded into the wizard controller and the
/// run-state file. Updated by the release workflow's "compute
/// version" step before `flutter build`. The default ('dev') keeps
/// non-release builds honest about what they are.
///
/// To override locally without editing this file, pass
/// `--dart-define=DECKHAND_VERSION=26.4.25-1731` to `flutter run` /
/// `flutter build`. The wizard controller surfaces this verbatim
/// into `~/.deckhand/run-state.json` so a maintainer reading a
/// debug bundle can correlate "this install was from release X".
library;

const String deckhandVersion = String.fromEnvironment(
  'DECKHAND_VERSION',
  defaultValue: 'dev',
);

/// Local-only escape hatch for optimized smoke testing when the repo still
/// contains the placeholder profile-trust keyring.
///
/// Production release workflows must never set this flag. It exists so a
/// maintainer can exercise Release-mode rendering/performance against a local
/// profile checkout without weakening the normal packaged artifact.
const bool localSmokeRelease = bool.fromEnvironment(
  'DECKHAND_LOCAL_SMOKE_RELEASE',
  defaultValue: false,
);

String describeBuildMode({required bool isReleaseBuild}) {
  if (isReleaseBuild && localSmokeRelease) return 'local-smoke-release';
  if (isReleaseBuild) return 'release';
  return 'development';
}
