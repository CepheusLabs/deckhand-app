# i18n (slang)

User-facing strings live in `i18n/en.i18n.yaml`. Slang consumes them at
build time and produces `lib/src/i18n/translations.g.dart`, which the
rest of the UI reads via `t.path.to.key`.

## Generating

```powershell
cd D:\git\3dprinting\deckhand\packages\deckhand_ui
D:\git\flutter\bin\flutter.bat pub run slang
```

## Adding a new string

1. Add the key under the appropriate section in `en.i18n.yaml`.
2. Re-generate (`flutter pub run slang`).
3. Reference from code: `t.<section>.<key>`.

## Adding a locale

1. Copy `en.i18n.yaml` to `<locale>.i18n.yaml` (e.g. `de.i18n.yaml`).
2. Translate values; keep keys and interpolations identical.
3. Re-generate.
