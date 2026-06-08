# Deckhand — Enterprise-Readiness Audit (state of the code)

> Date: 2026-06-05. Reviewer pass: function-level audit of the entire
> codebase (~98K LOC: ~83K Dart + ~15K Go), 18 module agents + a
> cross-cutting agent, every stub/high-impact claim adversarially
> re-verified against the source, plus a manual Go-toolchain run to
> confirm test/build claims.
>
> **Scope note.** Deckhand is the Klipper **flasher / setup / maintenance**
> tool (Flutter UI + privileged Go sidecar). It is **not** a slicer — that
> is a separate app (Anvil). This audit treats Deckhand as what it is.
>
> Companion document: [`ENTERPRISE-ROADMAP.md`](ENTERPRISE-ROADMAP.md).

## 1. Verdict

Deckhand is **not a prototype**. It is a genuinely well-architected, security-
conscious application whose *dangerous core* — disk flashing, the elevated
helper, OS-image download/verify, the JSON-RPC contract, crash recovery — is
already at or near production quality, with exceptional test coverage in those
areas (`deckhand_flash` ships ~1:1 test:source LOC). The design docs are
unusually honest and the threat model is real.

The gap to *enterprise* is therefore **not "build the missing 80%."** It is:

1. **A broken delivery gate.** All CI is `workflow_dispatch`-only (push/PR
   triggers were deliberately removed); the Go test suite is RED on
   macOS/Linux; release signing is optional; the repo can't be cloned-and-built
   standalone. The quality machinery exists and is switched off.
2. **A web/mobile story that is one-third built.** The desktop path is strong;
   the web path remains a large standalone surface with an under-hardened
   local-agent bridge; mobile does not exist.
3. **A small set of real functional gaps and one real security bug**, plus
   pervasive *sustainability* debt (god-files, duplication, hardcoded config)
   and *scalability* debt (missing cancellation/timeouts/streaming/backpressure)
   that is individually minor but collectively the difference between "works on
   my bench" and "operable as a fleet product."

Per your constraint — **no stubs, no patches, no deferred work** — every item
below is something the roadmap closes, not papers over.

## 2. Maturity census

~1,040 functions/methods/classes were classified. Of the 17 modules with
machine-counted totals (the 18th, `pkg-discovery-profiles`, is summarized
separately):

| Module | Maturity | prod | mvp | partial | stub |
|---|---|---:|---:|---:|---:|
| `deckhand_flash` (sidecar client, elevated helper) | **production** | 95 | 10 | 3 | 0 |
| `go-osimg-disks` (image dl/verify, disk enum, safety) | **production** | 33 | 5 | 0 | 1\* |
| `go-cmd` (sidecar + elevated-helper binaries) | **production** | 48 | 7 | 2 | 3\* |
| `core-services-models` (interfaces, DTOs, pure logic) | mixed→prod | 38 | 6 | 2 | 0 |
| `ui-screens-A` (manage/settings/connect/eMMC/tuning) | mvp | 95 | 22 | 8 | 0 |
| `ui-screens-B` (flash/verify/progress flow) | mvp | 38 | 14 | 5 | 0 |
| `ui-widgets-theming` (widgets, theme, i18n, utils) | mvp | 70 | 22 | 6 | 2 |
| `core-wizard-engine` (the orchestration brain) | mvp | 95 | 28 | 9 | 4 |
| `go-doctor` (preflight self-diagnostic) | mixed | 28 | 12 | 3 | 0 |
| `go-rpc-handlers` (JSON-RPC server + handlers) | mvp | 28 | 9 | 3 | 1 |
| `go-localagent-misc` (web bridge, logging, hash, host) | mvp | 28 | 8 | 2 | 0 |
| `deckhand_hitl` (headless HITL driver) | mvp | 28 | 9 | 4 | 8\* |
| `pkg-profile-lint` (profile YAML linter) | mvp | 18 | 9 | 3 | 1\* |
| `deckhand_ssh` (SSH/Moonraker/archive adapters) | mvp | 9 | 11 | 3 | 0 |
| `core-web` (browser transport/flash delegates) | mvp | 14 | 12 | 6 | 1 |
| `ui-screens-C` (firmware/webui/first-boot/hardening/…) | mvp | 14 | 18 | 6 | 1 |
| `app-shell` (desktop boot + web entrypoint + module) | mixed | 14 | 14 | 8 | 4\* |
| **Totals (17 modules)** | | **693** | **216** | **73** | **26** |

≈ **69 % production · 21 % MVP · 7 % partial · 3 % stub**.

`pkg-discovery-profiles` (3 packages, not in the totals above):
`deckhand_profiles` is mvp→production (strong validation; weak on
timeouts/concurrency); `deckhand_discovery` is mixed (pure CIDR logic is
production and well-tested; the *live* mDNS/scan/wait paths are MVP and
**entirely untested**); `deckhand_profile_script` is a deliberate,
production-quality **disabled gate** — see §3.5.

\* Most `stub`-flagged items are **intentional or correct**, not gaps — see §3.6
(false positives caught by verification).

### Verification honesty

Of the 32 riskiest stub/partial claims re-checked against source:
**16 confirmed, 8 overstated, 8 wrong.** Half of the scariest-sounding findings
were exaggerated or false (e.g. `DeckhandProductModule.events` returning an
empty stream was flagged a "stub" but is the *correct* implementation). Every
finding below survived that filter.

## 3. What is stubbed, partial, or MVP

### 3.1 P0 — Security bug (genuinely broken, must fix first)

- **Plaintext provisioning passwords are persisted to disk and leak into debug
  bundles.** `first_boot_setup_screen` and `hardening_screen` write the
  user-chosen password into the wizard *decisions* map via `setDecision`
  (`first_boot_setup_screen.dart:300`, `hardening_screen.dart:108`).
  `WizardState.toJson()` serializes the decisions map verbatim and
  `isPersistableWizardState` flushes it to
  `<data_dir>/state/wizard_session.json` — **directly contradicting the
  `WizardState` docstring's "secrets are NEVER serialized" guarantee.** Those
  keys (`first_boot.password`, `hardening.new_password`) are also absent from
  `redactionSessionValues()`, so they pass un-redacted into "Save debug bundle"
  zips. Compounding it: no password strength/length gate, and the hardening
  "strength meter" is length-only (rates repeated characters "VERY STRONG").

### 3.2 Genuine functional gaps (declared-but-unimplemented)

These throw, silently pass, or no-op where a real implementation is expected:

- **`version.compat` is intentionally single-contract today** — it returns
  `{"compatible": true, "sidecar_version": ..., "ui_version": ...}` for every
  decoded UI version because no breaking sidecar/UI contract exists yet. The
  future gap is a policy gate once staged rollout needs a minimum UI/sidecar
  contract version.
- **`resume=continue` is unimplemented** — an interrupted step declaring this
  documented resume mode hard-fails the wizard on retry
  (`wizard_controller_runtime.dart:245`).
- **`moonraker_gcode` verifier is implemented** — it dispatches the declared
  `script`/`gcode` through `MoonrakerService.runGCode`, fails non-optional
  verifiers on Moonraker errors, and skips only when no host is recorded.
- **`restore_from_backup` screen kind is unimplemented** — throws
  (`wizard_controller_steps.dart:260`); only `bundled` source kinds work.
  (Already tracked in [`BACKLOG.md`](BACKLOG.md).)
- **S900 resume-preview UI is missing** — the run-state data model is wired and
  real, but the "continuing / re-running / skipping" renderer the resume
  contract specifies does not exist (per
  [`STEP-IDEMPOTENCY.md`](STEP-IDEMPOTENCY.md) "Implementation status").
- **Checkpointed step continuation** is unbuilt and rejected by profile-lint —
  steps that need byte/range checkpoints must `cleanup_then_restart`
  (`STEP-IDEMPOTENCY.md`).
- **Debug-bundle zip assembly is pending v1** — the review surface exists but
  the artifact-write pipeline does not (`ui-screens-C`).
- **`DeckhandProductModule.taskStatus` / `taskCancel` are stubs** — they
  unconditionally return `failed` (`app/lib/deckhand_product_module.dart:141`)
  even though the module exposes a **destructive image-apply capability to
  agents over MCP/nexus**. The lifecycle that would let an agent poll/cancel a
  flash is absent.
- **`_ordinalLabel` fabricates fake timestamps** in the log view and presents
  them as real time (`wizard_log_view.dart:248`) — they also pollute copied
  logs.

### 3.3 The disabled profile-script runtime (intentional, but it is a hole)

`deckhand_profile_script` ships the *type-only* API
(`ScriptContext`, `ProfileScriptHost`, annotations) so profile authors can
compile against a stable contract, but `ProfileScriptRuntime.loadScript`
**always throws `ProfileScriptDisabledException`** (`runtime.dart:23-39`;
verified). The actual `runner.dart` and `sandbox/` that
[`ARCHITECTURE.md`](ARCHITECTURE.md) advertises **do not exist on disk**. The
runtime stays disabled until a capability-scoped isolate sandbox + static-
analysis pass + signed-tag gating ship *together*. This is the correct call for
v1, but for "no deferred work" it is a whole capability that the roadmap must
either build properly or formally cut.

### 3.4 The web surface (one-third built, MVP/demo grade)

- **`main_web.dart` is an 823-line god-widget** — all state, transport
  orchestration, file I/O, blob downloads, and five inline panels in one
  `StatefulWidget` with no state management, no router, no tests, no
  cancellation/timeout (`app/lib/main_web.dart:35`). It diverges entirely from
  the (strong) desktop architecture.
- **Browser flash delegates are happy-path only.** `WebSerialBootloaderDelegate`
  and `WebUsbDfuDelegate` push chunks with **no per-write ACK, no flow control,
  no timeout, no cancellation, and no verify phase** — and `WebUsbDfuDelegate`
  omits the DFU `GET_STATUS` poll, manifest/leave, and zero-length terminating
  packet (`browser_flash_delegates.dart:74,124`). These are not edge cases for
  firmware flashing; they are core correctness/safety.
  `DeckhandTransportPhase.verifying`/`.failed` enum values exist but are never
  emitted — dead protocol surface.
- Whole firmware images are loaded into memory with **no size guard**
  (`main_web.dart:147`) — a large `.img` OOMs the tab.
- **Resolved follow-up: browser interop migration** — active web entrypoints now
  use `package:web` + `dart:js_interop`; `flutter build web` and the Wasm dry
  run pass. The architectural gaps above remain.

### 3.5 MVP corner-cutting that recurs everywhere

The dominant pattern across the MVP modules is the *same five gaps*, repeated:

- **No cancellation** of long operations — the wizard only checks cancellation
  at step boundaries, so an in-flight git clone / disk write / 10-min SSH poll
  can't be aborted (`wizard_controller_runtime.dart:148`,
  `first_boot_screen.dart:57`, all `deckhand_ssh` streaming paths, all
  `core-web` delegates).
- **No timeouts/deadlines** on raw I/O — the elevated helper has no read
  deadline on raw-device handles (`go-cmd`); SSH/Moonraker/HTTP fetches lean on
  library defaults; subprocess listers (`lsblk`/`diskutil`/PowerShell) have no
  internal timeout (`go-osimg-disks`).
- **Load-everything-into-memory** — `upload`/`download` read whole files
  (`deckhand_ssh`); backup `find` is unbounded across `/etc /home /opt /var
  /srv` (`printer_state_probe.dart:316`); progress files are re-read from byte 0
  every 2 s (`go-doctor`, Windows elevated progress busy-polls every 150 ms);
  in-UI log/egress/preview buffers grow unbounded (`progress_screen`,
  `verify_screen._preview`).
- **No backpressure** — the local-agent SSE stream drops events on slow
  consumers via non-blocking send with a fixed 16-deep buffer
  (`localagent/server.go:362`); every sidecar event triggers a synchronous
  `setState` rebuild.
- **No retry/backoff** on any network/SSH operation — every transient failure
  is terminal for the step.

### 3.6 What verification proved is *fine* (do not "fix")

- `disks.WriteImage` returning `ErrElevationRequired` (`disks/write.go:15`) is
  the **documented elevation boundary**, not a stub.
- `DeckhandProductModule.events` (empty stream) and `contextSnapshot` are
  **correct** implementations (verified "wrong" claims).
- The `Stub*` services in `deckhand_hitl` are intentional, `@internal`,
  barrel-excluded, CI-only test doubles with "devastating in production"
  warnings — exemplary discipline, not debt.
- Unix `isRetryableRawWriteError`/`platformTerminalDeviceReadError` returning
  `false` are legitimate platform-specific no-ops (the Windows variants carry
  the logic). **Exception:** `prepareWriteTarget` being a Unix no-op *is* a real
  gap — Unix doesn't lock/quiesce mounted filesystems before a raw write the way
  Windows does (`raw_device_unix.go:17`).

## 4. Security findings (beyond the P0)

- **The local-agent web bridge is the soft underbelly** (`localagent/server.go`).
  Default CORS allows **any** `https://` origin to reach a privileged raw-disk
  agent when `--allow-origin` is unset; the bearer token is compared with `==`
  (not constant-time) and accepted via **URL query param** (leaks into logs);
  an empty token disables auth but the process still starts; raw `err.Error()`
  strings are returned to web callers, **bypassing the IPC error sanitizer**
  (disk paths, repo URLs, possibly tokens-in-URLs disclosed to JavaScript); no
  request-body size cap; the operation registry never evicts (memory leak); no
  per-method authorization (any registered RPC reachable from the browser).
- **Web token handling** — the local-agent bearer token is compiled into the JS
  bundle via `String.fromEnvironment` and additionally passed as `?token=`
  (`main_web.dart:21`, `local_agent_client.dart:118`).
- **Elevated-helper watchdog is PID-reuse-vulnerable** — no cookie/handshake, so
  a recycled parent PID can keep an elevated write alive (`watchdog_*.go`).
- **`localhost`/loopback is permanently in the production download allowlist**
  (`osimg/fetch.go:802`) — a narrow SSRF-to-loopback surface for a privileged
  process; should be test-only.
- **TOCTOU at flash commit** — `flash_confirm._commit` does not re-validate the
  target disk between user confirmation and the destructive handoff
  (`flash_confirm_screen.dart:76`); a re-enumerated device could be wiped.
- **SSH host-key verification fails open** when no `SecurityService` is wired
  (`dartssh_service.dart:53`); production wires a store (so this is overstated),
  but the default should fail closed.
- **No committed production trust root** — `app/assets/keyring.asc` is a
  placeholder; signed-tag enforcement depends on a release-time secret swap.
  (Mitigated: release builds fail closed on the placeholder.)
- **GitHub PAT hydrated into a show-able plaintext `TextEditingController`**
  (`settings_screen.dart:94`), leaving the secret in widget memory.
- Token single-use/TTL is enforced only by the unprivileged controller; the
  privileged helper trusts the manifest binding (a documented, reasonable
  trade-off, but a stolen valid `(manifest, token-file)` pair pre-consumption is
  a real window — `go-cmd`).

## 5. Cross-cutting / delivery (the highest-leverage gaps)

- **All CI is `workflow_dispatch`-only.** Commit `e50ec45` ("disable commit-
  triggered workflows") removed `push:`/`pull_request:` from `ci.yml`/
  `security.yml` and the tag triggers from `release.yml`/`hitl.yml`. A thorough
  gate suite (go vet, race tests, coverage floors, golangci-lint, IPC-docs drift
  check, `flutter analyze --fatal-infos`, format check, profile-lint) exists and
  **never runs automatically. There is no PR gate.** This is the single biggest
  enterprise-readiness gap.
- **The Go test suite is RED outside the pinned toolchain** (verified by running
  it): `go test ./...` exits 1 on macOS/Linux because
  `cmd/.../main_test.go:455` hardcodes the Windows id `PhysicalDrive3` with no
  build tag; and `go vet` fails under the CI-pinned Go 1.22 because
  `doctor/download_os_test.go` uses `t.Context()` (Go 1.24+) while `go.mod` says
  `go 1.22`.
- **Release signing is optional and silently downgrades to unsigned** — Windows
  Authenticode, macOS Developer-ID + notarization, and Linux GPG are each gated
  on a secret being present; absent it, the lane ships an **unsigned privileged
  helper**. For a firmware/disk tool this is an enterprise blocker.
- **Resolved follow-up: clone/build dependency wiring** — first-party external
  packages are now committed as explicit git pins, with sibling `main` checkouts
  reserved for local development/tool overrides.
- **Dependency lag** — Riverpod 2→3, go_router 14→17, bonsoir 5→7 (mDNS, two
  majors behind), plus unmerged patch bumps for `xz` (the image decompressor),
  `go-git`, and `x/sys`. Nine open Dependabot branches, none merged (consistent
  with disabled CI).
- **Observability is thin** — opt-in anonymous telemetry exists
  (`telescope_integration.dart`) but emits one event; **no crash reporting
  anywhere**; structured-logging foundations exist (Go `logging`, Dart
  `logging.dart`) but most modules log free-text English with no levels,
  correlation IDs, or metrics. There is **no tamper-evident audit log of
  destructive operations** suitable for compliance.
- **Docs drift** — `ARCHITECTURE.md` references `sidecar/internal/os_images`
  (real dir is `osimg`), a hardcoded `D:\git\flutter\bin\flutter.bat` dev path,
  and a `PROFILE-SCHEMA.md` that does not exist; the release "Windows (MSI)" job
  actually builds an Inno `.exe`.
- **Conflicting release machinery** — a `release-please--…` branch exists but no
  release-please config is committed; `release.yml` hand-rolls CalVer.
- **Resolved follow-up: first-party dependency model** — submodules/gitlinks are
  removed from Deckhand; first-party external packages use explicit git refs.

## 6. Sustainability debt (maintainability)

- **God-files** that decomposition would de-risk: `WizardController` (5 `part
  of` files + ~40 one-line dispatcher shims, split only to dodge an 800-line
  lint ceiling — cosmetic, not architectural); `main_web.dart` (823);
  `handlers.go` (single 1041-line `Register()`); `process_elevated_helper.dart`
  (1201, with a ~350-line `_runWindows`); `lint.dart` (1129); the management
  screens (`manage_screen` 2666, `settings` 1745, `connect` 1742, `emmc_backup`
  1715, `snapshot` 1331).
- **Duplication with drift risk**: JSON-coercion helpers copy-pasted across 5
  files in `deckhand_flash`; byte-humanizing reimplemented 4× with different
  rounding; three parallel route↔id maps with a documented "user stranded"
  failure mode if they drift; path-validation logic duplicated across 4+
  functions in `go-rpc-handlers`; `writeManifest` struct defined twice and hand-
  kept-in-sync.
- **Dead code**: `DiscoveryBackend` seam (test-only, masquerading as
  production); `WorkshopGrid`/`StatusStrip` widgets; `powerShellDoubleQuoted`;
  `busTypeName`; the `_sessionAskpass` reuse machinery (field never assigned, its
  docstring promises behavior that doesn't happen).
- **Config sprawl**: operationally important constants are compile-time literals
  scattered through code (concurrency caps, redirect caps, restart/backoff,
  timeouts, ports, buffer sizes, progress thresholds) — no central, overridable
  config for air-gapped/enterprise/mirror deployments.
- **i18n half-migrated**: Slang is wired, but only a handful of screens use it.
  ~9 of 16 `ui-screens-C` files, the management screens, the **destructive**
  welcome/snapshot/flash-confirm screens, the desktop **fatal-error** screen,
  and ~29 of ~30 widgets hardcode English — including security-relevant copy.
- **Coupling to backend wording**: UI error/log humanization substring-matches
  exact sidecar English strings — fragile and unlocalizable.

## 7. Scalability debt (operability at fleet scale)

- Run-state is written to the printer via two awaited SSH round-trips **per
  step** with no coalescing (the host-side store *does* coalesce — asymmetry).
- The CIDR sweep, registry spec-fallback (`fetchRegistry`), and profile fan-out
  are unbounded or head-of-line-blocked; discovery returns batches, not streams.
- The RPC server's **global concurrency limit is shared by the control plane** —
  under load `jobs.cancel`/`shutdown` can be rejected, the opposite of graceful;
  `globalLimit=0` removes all bounds.
- Progress notifications marshal→unmarshal→marshal per call on the IPC hot path.
- Animated `CustomPainter`s repaint every frame with no `RepaintBoundary`.
- No request-body size cap on the web bridge; a 16 MiB+ JSON line silently
  terminates the stdio read loop instead of returning a structured error.

## 8. What is genuinely strong (preserve through any refactor)

- `deckhand_flash` and `go-osimg-disks`: defense-in-depth disk/elevation/
  download paths — TOCTOU mitigations, symlink/traversal rejection, O_EXCL
  atomic temp-then-rename, sha256 gating on every download, exclusive 0600/0700
  temp files, watchdog self-termination, typed crash-recovery state machine,
  fuzz-tested safety verdict, ~1:1 test:source coverage.
- The elevated-helper privilege model: single-op binary, manifest-bound
  token/image/target/expiry, per-path-layer `lstat` symlink checks, strict
  per-OS device allowlists, Windows volume lock/dismount fail-closed.
- The RPC core: typed error codes, generation-counted job cancellation, panic
  recovery, secret/URL redaction, fuzz-tested param validator, mutex-serialized
  writer.
- The wizard engine's security posture: single-quoted shell interpolation,
  validated profile inputs, confirmation-token consumption, secrets excluded
  from persisted state (the §3.1 password bug is the one place this slipped).
- Release engineering *design*: CalVer, dual-format SBOM (SPDX + CycloneDX),
  SHA-pinned actions + SHA256-verified tool downloads, signed checksums,
  documented rollback — strong when it runs.
- Theming: correct OKLCH→sRGB design-token system with `copyWith`/`lerp`.

See [`ENTERPRISE-ROADMAP.md`](ENTERPRISE-ROADMAP.md) for how this becomes
enterprise-grade.
