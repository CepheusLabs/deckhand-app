# Deckhand — Architecture

> Deckhand is a cross-platform desktop app (Flutter UI + Go sidecar) that
> flashes, sets up, and maintains Klipper-based 3D printers.

## Design principles

1. **Organized as Dart/Flutter packages.** Core logic, profile handling,
   SSH, disk operations, discovery, and UI each live in their own package
   under `packages/`. Keeps the codebase testable (pure-logic packages
   don't depend on Flutter) and the wizard app shell thin.
2. **Interfaces over implementations.** Every privileged capability (SSH,
   disk flash, profile fetch, mDNS, etc.) is an interface with a concrete
   implementation wired in at app startup via Riverpod overrides. Makes
   testing straightforward and swaps possible.
3. **Cross-platform where possible, platform-specific where necessary.**
   Pure Dart for models, profile handling, SSH, UI. Platform-specific code
   only where required (disk flashing requires admin/root).
4. **Modern Flutter stack.** Flutter 3.38 / Dart 3.10, Riverpod 2.x,
   GoRouter, Freezed + json_serializable, Dio, `flutter_secure_storage`,
   Slang i18n, Material 3.
5. **No hosted backend.** The app runs fully local; the only network
   traffic is direct — to the user's printer on LAN and to public upstream
   sources (GitHub, Armbian) for downloads.
6. **Non-technical users welcome.** Wizard screens are the default path.
   Technical users can drop into YAML authoring and CLI mode.

## High-level shape

```
┌────────────────────────────────────────────────┐
│  Flutter desktop app  (Dart)                   │
│    - Wizard screens                            │
│    - Progress / log panels                     │
│    - Settings / connections                    │
└───────────────┬────────────────────────────────┘
                │  JSON-RPC 2.0 over stdin/stdout
                │
┌───────────────▼────────────────────────────────┐
│  Go sidecar  (deckhand-sidecar)                │
│    - Disk I/O (flash, dd, enumerate)           │
│    - Shallow git clone (go-git)                │
│    - HTTP fetch + sha256 verify                │
│    - Host info helpers                         │
└───────────────┬────────────────────────────────┘
                │  on-demand
                ▼
┌────────────────────────────────────────────────┐
│  deckhand-elevated-helper                      │
│    - Single-op elevated binary                 │
│    - Disk writes under UAC / pkexec / osascript│
└────────────────────────────────────────────────┘
                │
                ▼
  Public sources + the user's printer on LAN.
```

## Repo layout

```
deckhand/
├── README.md
├── LICENSE                              # TBD
├── docs/
│   ├── ARCHITECTURE.md                  # this file
│   ├── WIZARD-FLOW.md                   # screen-by-screen UX spec
│   ├── IPC.md                           # sidecar JSON-RPC method catalog
│   ├── PROFILE-SCHEMA.md                # profile.yaml spec (content authored in deckhand-builds, lives here)
│   └── RELEASING.md                     # versioning, tagging, CI
├── app/                                 # Deckhand desktop app
│   ├── pubspec.yaml                     # depends on deckhand_* packages
│   └── lib/main.dart                    # bootstraps with sidecar adapters
├── packages/
│   ├── deckhand_core/                   # platform-agnostic, UI-agnostic
│   │   ├── pubspec.yaml
│   │   └── lib/
│   │       ├── src/
│   │       │   ├── models/              # freezed: Profile, Printer, Session, ...
│   │       │   ├── services/            # interfaces only
│   │       │   └── wizard/              # state machine for the install flow
│   │       └── deckhand_core.dart
│   ├── deckhand_profiles/               # consumes deckhand_core
│   │   └── lib/
│   │       └── src/
│   │           ├── fetcher.dart         # dio-based zip/archive fetch
│   │           ├── parser.dart          # yaml → models
│   │           └── registry.dart        # list available profiles
│   ├── deckhand_ssh/                    # consumes deckhand_core
│   │   └── lib/
│   │       └── src/
│   │           ├── client.dart          # dartssh2 wrapper
│   │           ├── moonraker.dart       # JSON-RPC over WS
│   │           └── credentials.dart     # default-creds helpers
│   ├── deckhand_flash/                  # interface + platform-specific helpers
│   │   ├── lib/
│   │   │   └── src/
│   │   │       ├── flash_service.dart   # abstract interface
│   │   │       ├── disk_info.dart       # models
│   │   │       └── sidecar_adapter.dart # wrapping the Go sidecar
│   │   └── (native code lives in app's platform dir OR in the sidecar)
│   ├── deckhand_discovery/              # mDNS, LAN scan
│   │   └── lib/
│   │       └── src/
│   │           ├── mdns.dart            # bonsoir / nsd
│   │           └── cidr_scan.dart
│   ├── deckhand_ui/                     # Flutter widgets — wizard screens
│   │   └── lib/
│   │       └── src/
│   │           ├── screens/             # wizard screens
│   │           ├── widgets/             # shared UI components
│   │           └── theming/             # material 3 theme
│   └── deckhand_profile_script/         # sandboxed API for profile-shipped scripts
│       └── lib/
│           └── src/
│               ├── api.dart             # ScriptContext + annotation types
│               ├── runner.dart          # loads & runs Dart scripts in restricted isolate
│               └── sandbox/             # static analysis + runtime guards
├── sidecar/                             # Go sidecar (Go-backed privileged ops)
│   ├── go.mod
│   ├── cmd/deckhand-sidecar/main.go
│   └── internal/
│       ├── rpc/                         # JSON-RPC over stdio
│       ├── disks/                       # per-OS disk enumeration + flash
│       ├── os_images/                   # HTTP fetch + sha256
│       ├── hash/                        # streaming sha256
│       └── host/
├── scripts/                             # build + release helpers
└── .github/workflows/                   # CI matrix
```

## Package boundaries and dependencies

```
deckhand_core              (no deckhand_* deps — pure Dart)
    ▲
    │
deckhand_profile_script  ← (pure Dart, consumed only by profile authors)
deckhand_profiles ─┐
deckhand_ssh ──────┤
deckhand_discovery ┤
deckhand_flash ────┘
    ▲
    │
deckhand_ui                (Flutter widgets, consumes everything above)
```

External deps:

- `dio ^5.9.1` (HTTP)
- `freezed ^3.0.0` + `json_serializable ^6.x`
- `flutter_riverpod ^2.6.1`
- `go_router ^14.0.0`
- `flutter_secure_storage ^10.0.0`
- `slang ^4.0.0`
- `dartssh2` — SSH
- `bonsoir` or `nsd` — mDNS
- `yaml ^3.x` — profile parsing
- `uuid ^4.0.0`
- `path ^1.9.0`
- `path_provider ^2.1.0`
- `sqlite3_flutter_libs` + `drift` if we need local persistence beyond JSON

## Interface pattern

Every privileged / host-specific capability is an abstract class in
`deckhand_core`. Concrete implementations live in their own package under
`packages/`. Wiring happens at app startup via Riverpod overrides — so
tests can inject fakes and production wires in real implementations
without any code in `deckhand_core` caring about the difference.

```dart
// packages/deckhand_core/lib/src/services/flash_service.dart
abstract class FlashService {
  Future<List<DiskInfo>> listDisks();
  Stream<FlashProgress> writeImage({
    required String imagePath,
    required String diskId,
    required String confirmationToken,
  });
  Future<String> sha256(String path);
}
```

```dart
// packages/deckhand_flash/lib/src/sidecar_adapter.dart
class SidecarFlashService implements FlashService {
  SidecarFlashService(this._sidecar);
  final SidecarClient _sidecar;

  @override
  Future<List<DiskInfo>> listDisks() async {
    final res = await _sidecar.call('disks.list', {});
    return (res as List).map(DiskInfo.fromJson).toList();
  }
  // …
}
```

```dart
// app/lib/main.dart
final container = ProviderContainer(overrides: [
  flashServiceProvider.overrideWithValue(SidecarFlashService(sidecar)),
  sshServiceProvider.overrideWithValue(DartSshService()),
  // …
]);
```

For tests, the same providers are overridden with fakes:

```dart
// packages/deckhand_core/test/flash_flow_test.dart
testWidgets('flash flow reports progress', (tester) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [flashServiceProvider.overrideWithValue(FakeFlashService())],
    child: const App(),
  ));
  // ...
});
```

## Go sidecar (Go-backed privileged ops)

The sidecar is a small Go binary that Deckhand spawns as a
child process at launch. It exists because Dart can't do elevated disk I/O
portably — Go has better primitives and cross-compiles trivially.

**IPC**: JSON-RPC 2.0 over stdin/stdout, newline-delimited.

**Scope**: only the operations Dart can't do well.

- `disks.list` — enumerate local disks (USB, internal, sizes, partitions)
- `disks.read_image` — dd a disk to an image file (for backups)
- `disks.write_image` — dd an image to a disk (for fresh-flash flows)
- `disks.hash` — streaming sha256 of a file
- `os.download` — HTTP fetch with progress + sha256 verify
- `profiles.fetch` — git shallow-clone a profile repo ref via go-git
- `host.info` — OS / arch / data dirs
- Lifecycle: `ping`, `shutdown`, `version.compat`

**Not in scope** (Dart handles these):
- SSH → `dartssh2`
- Moonraker → Dart WS client
- mDNS → `bonsoir` / `nsd`
- HTTP for small requests → `dio`
- YAML / JSON parsing → Dart stdlib + `yaml` package
- UI / state / navigation → Flutter
- Keychain → `flutter_secure_storage`

**Elevation**: the sidecar runs as the user at launch. Elevated operations
(disk flash, image write, certain Linux device-file reads) go through a
separate small helper binary:

- **Helper binary**: `deckhand-elevated-helper` (Go, single file). Ships
  alongside the main sidecar. No persistent state, no network access
  (enforced in the build), no stdin — takes arguments on the command line
  and writes progress to stdout.
- **Invocation**: when the sidecar needs an elevated op, it requests
  elevation from Flutter, which launches the helper with the user's OS
  elevation prompt:
  - Windows: `ShellExecuteW` with `runas` verb (UAC prompt)
  - macOS: `osascript -e 'do shell script … with administrator privileges'`
    or `AuthorizationExecuteWithPrivileges`
  - Linux: `pkexec` with a PolicyKit action declaring the helper's scope
- **Surface**: the helper performs exactly one operation then exits. No
  persistent elevated process. Each invocation is logged with its arguments
  and exit status.

Rationale for separate helper over sidecar relaunch: the elevated surface
is tiny (one binary, one op at a time), easier to audit and sign, and
isolates any privileged code from the sidecar's larger attack surface.

## Per-user data directories

| OS | Path |
|----|------|
| Windows | `%LOCALAPPDATA%\Deckhand\` |
| macOS | `~/Library/Application Support/Deckhand/` |
| Linux | `$XDG_DATA_HOME/deckhand/` (fallback `~/.local/share/deckhand/`) |

```
<data_dir>/
├── cache/
│   ├── profiles/<tag>/                # cached deckhand-builds checkouts
│   ├── os-images/                     # verified OS images
│   └── upstream/                      # cloned klipper/kalico/etc
├── state/
│   ├── connections.json               # saved SSH endpoints (secrets in OS keychain)
│   └── recent_activity.json
├── logs/                              # session logs
└── settings.json
```

`deckhand_core` takes a `DeckhandPaths` object at bootstrap so tests can
redirect cache/state into temp directories.

## Profile fetch strategy

Deckhand never bundles profile content. On demand:

1. Fetch `registry.yaml` from `CepheusLabs/deckhand-builds` main (tiny file).
2. Resolve the latest semver tag (or a user-pinned tag).
3. Shallow-clone that tag into the cache via the sidecar's `profiles.fetch`
   (`go-git` with `depth=1`).
4. Load `printers/<id>/profile.yaml` from the cached checkout.

## Upstream fetch strategy (Klipper / Moonraker / Fluidd / Mainsail)

Profile declares URLs + refs. The sidecar fetches:

- Git refs → shallow clone into `cache/upstream/<repo_hash>/<ref>/`
- GitHub Releases assets → download with sha256 verify

Unauthenticated GitHub API allows 60 req/hour. If hit, the UI prompts for a
personal access token (stored in OS keychain).

## Wizard flow (summary)

Full screen-by-screen in `WIZARD-FLOW.md`. The high-level branch:

```
[Start] → Do you want to keep your current OS or flash a new one?
   ├─ Keep stock OS → Flow A (in-place conversion wizard)
   └─ Flash fresh OS → Flow B (clean install wizard)
```

Flow A asks printer-specific questions (what to remove/keep) driven by
`profile.yaml` declarations for that printer. Flow B drives an OS flash →
first boot → stack install → ChromaKit/extras install.

## Packaging

| OS | Artifact | Signing |
|----|----------|---------|
| Windows | `.msi` via WiX or Inno Setup | Unsigned initially; Authenticode cert is future work |
| macOS | `.dmg` with notarized `.app` | Needs Apple Developer ID; can ship unsigned with user-side quarantine removal until then |
| Linux | `.AppImage` + `.deb` | No signing required |

Sidecar is bundled alongside the app binary. On install:

- Windows: sidecar at `<install>\deckhand-sidecar.exe`
- macOS: `Deckhand.app/Contents/MacOS/deckhand-sidecar`
- Linux: `<install>/deckhand-sidecar` (next to the Flutter binary)

## Versioning

- **Deckhand** uses SemVer. Every tag triggers a release build. Packages in
  `packages/` share the repo version.
- **Profile schema** has its own `schema_version` (starts at `1`). Schema
  major bumps require Deckhand release bump too. Deckhand supports current
  schema + one back.
- **Sidecar** has its own version. UI asserts compatibility on launch via
  `version.compat`.

## Security model

- **Destructive-op confirmation tokens** — sidecar methods like
  `disks.write_image` require a `confirmation_token` issued by a UI-only
  dialog, single-use, 60s TTL.
- **SSH host key pinning** — first-connection prompt, stored fingerprint in
  `state/known_hosts.json`.
- **Profile integrity** — tagged profile checkouts are immutable once
  published; Deckhand records the resolved commit SHA in each operation log.
- **No unauthenticated code execution** — scripts from profiles are executed
  only with explicit user consent in the UI, with their source hash
  displayed.
- **Network allow-list (strict by default)** — Deckhand ships with an empty
  host allow-list. Any outbound connection (GitHub, Armbian mirror, the
  printer's IP, etc.) triggers a one-time "Allow this host?" prompt in the
  UI showing the URL + the operation that requested it. Approvals persist
  to `settings.json`; users can revoke them in Settings. Profiles can
  declare their required hosts up front (`profile.yaml` field) so the
  wizard can batch-approve them at install start with one prompt instead of
  many per-step interruptions.

## Build prerequisites (contributor)

- **Flutter 3.38.9**
- **Dart 3.10.8**
- **Go 1.22+** (for sidecar; only needed if you touch sidecar code)
- Windows: VS Build Tools (C++ workload)
- macOS: Xcode CLI tools
- Linux: `cmake`, `ninja`, `libgtk-3-dev`, `libsecret-1-dev`

Flutter path on this dev machine: `D:\git\flutter\bin\flutter.bat`.

## Testing strategy

- **Dart unit tests** — `flutter test` per package. High coverage for
  `deckhand_core` (pure logic) and serializers.
- **Sidecar unit tests** — Go table-driven tests for each handler.
- **Integration tests** — Dart `integration_test` hitting a real sidecar
  (via spawn) for end-to-end flows.
- **Profile validation** — YAML lint + schema validation in CI on
  deckhand-builds (separate repo, invoked via its own CI).
- **Hardware-in-the-loop** — manual, per-release. Document protocol in
  `RELEASING.md`.

## Decided

1. **License** — AGPL-3.0 for both `deckhand` and `deckhand-builds`.
2. **i18n** — Slang wired from day one, English-only strings at v1,
   additional locales added incrementally.
3. **SSH library** — `dartssh2`.
4. **Elevation model** — separate `deckhand-elevated-helper` binary for
   flash ops; sidecar stays unprivileged.
5. **Network policy** — strict allow-list, empty by default, profile-declared
   hosts batch-approved at wizard start.

## Open decisions (non-blocking)

1. **Auto-update** — Deckhand self-update vs. rely on OS package managers.
2. **Crash reporting** — local-only log collection vs. opt-in remote.
3. **Profile signing** — GPG-signed tags on deckhand-builds, verified on
   fetch? Adds trust for public contributors but complicates signing flow.
4. **Build matrix for Linux** — single `.AppImage` covering most distros
   vs. per-distro `.deb` / `.rpm` builds.
