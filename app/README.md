# Deckhand desktop app

The thin Flutter shell that wires together the `deckhand_*` packages.

## Running in development

```powershell
cd app
flutter pub get
flutter run -d windows
```

(Linux/macOS: `-d linux` / `-d macos` respectively.)

## Release build

Releases run through the cepheus-build flow — see
[`../docs/RELEASING.md`](../docs/RELEASING.md). For a local release-style
build:

```powershell
cd /d/git/CepheusLabs/deckhand-app
../cepheus-build/bin/cepheus-build build -p deckhand desktop
```

(`desktop` = `macos windows linux`; pass a single target like `windows`
to build just one.)
