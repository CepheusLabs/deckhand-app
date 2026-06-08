# Deckhand — Enterprise-Readiness Roadmap

> Companion to [`ENTERPRISE-AUDIT.md`](ENTERPRISE-AUDIT.md) (the state-of-code
> findings this roadmap acts on). Target: make Deckhand — the Klipper
> flasher/setup/maintenance tool — **enterprise-grade**, with **Desktop, Web,
> Mobile, and Headless/CLI all first-class**, built for scalability and
> sustainability. No backward-compatibility constraints. **No stubs, no
> patches, no hack jobs, no deferred work**: each item below is *built*, not
> flagged.

## 0. Guiding principles (the "definition of done" for every item)

These are the standards the roadmap holds itself to. They turn "enterprise-
ready" from an adjective into a checklist applied to every change:

1. **Every privileged/long-running operation is cancellable, deadline-bounded,
   and streamed.** A `CancellationToken` (Dart) / `context.Context` (Go) is
   threaded end-to-end; no operation can hang without an upper bound; progress
   is a stream with backpressure, never an in-memory buffer that grows with the
   job.
2. **No secret ever touches disk, logs, the JS bundle, or a debug bundle**
   unredacted. Enforced by types and tests, not convention.
3. **Config is data, not code.** Operational constants (timeouts, caps, ports,
   allowlists, thresholds) live in a single typed, environment-overridable
   config layer — so air-gapped/mirror/enterprise deployments need no rebuild.
4. **One source of truth.** Each contract (route graph, RPC method list,
   capability vocabulary, manifest struct, byte formatting) is defined once and
   consumed everywhere; drift is a compile error, not a runbook risk.
5. **Observable by default.** Structured logging with levels + a correlation id
   spanning UI→sidecar→helper; metrics on every operation; opt-in crash
   reporting; a tamper-evident audit log of destructive actions.
6. **The gate is mandatory and green.** Nothing merges without CI passing on
   every target platform; nothing releases unsigned.
7. **No stub ships.** A capability is either fully built and tested, or formally
   cut from scope and removed from the code/docs — never left as a throwing
   placeholder.

## 1. Platform strategy (the central architectural decision)

Deckhand's value — raw-disk flashing and on-printer setup — runs through a
**privileged Go sidecar + single-op elevated helper that cannot exist in a
browser or on a phone.** Making web and mobile *first-class* therefore is not a
UI port; it is a deliberate capability-tiering exercise. The roadmap adopts an
explicit **capability matrix** and a **single transport-capability layer** that
every platform shares.

### Capability matrix (the contract the whole app is built around)

| Capability | Desktop | Web | Mobile | CLI |
|---|---|---|---|---|
| Raw-disk / eMMC flash (image→disk) | ✅ sidecar + elevated helper | ⚠️ via **Local Agent** bridge (desktop companion) | ❌ (no raw block access) | ✅ sidecar |
| MCU firmware flash (DFU/serial/HID) | ✅ | ✅ **WebUSB/WebSerial/WebHID** | ✅ Android WebUSB/USB-OTG · ❌ iOS | ✅ |
| OS-image download + verify | ✅ sidecar | ⚠️ via Local Agent | ❌ (delegate to agent) | ✅ |
| SSH setup / Moonraker mgmt | ✅ | ⚠️ via Local Agent | ✅ (pure-Dart SSH/WS, LAN) | ✅ |
| Printer discovery (mDNS/scan) | ✅ | ⚠️ Local Agent (no raw mDNS in browser) | ✅ (platform mDNS) | ✅ |
| Monitoring / status / tuning | ✅ | ✅ (direct Moonraker over LAN) | ✅ | ✅ |
| Profile authoring / lint | ✅ | ✅ | — | ✅ |

✅ native · ⚠️ requires the **Local Agent** (a Deckhand sidecar running in
`agent` mode on a machine with the hardware) · ❌ not offered (and the UI says
so, gracefully).

The strategic consequence: **the Local Agent HTTP/SSE bridge is promoted from an
MVP afterthought to a first-class, hardened product surface** — it is what makes
web and mobile able to flash at all. Mobile's *own* first-class story is
**remote fleet management + monitoring + MCU flashing (Android)**, with disk
flashing explicitly delegated to a paired desktop/agent.

### The transport-capability layer

Today `core-web` already models surface gating
(`browser`/`local-agent`/`desktop`/`unavailable`) — but the requirement
vocabulary is stringly-typed and duplicated across 6+ sites, and the delegates
are happy-path only. The roadmap **unifies** this into one typed capability
module shared by all four platforms, so a profile step's
`transport_requirements` resolve identically everywhere and the UI can always
tell the user *why* a step is or isn't available on their platform.

## 2. Phased plan

Phases are ordered by **dependency and risk**, not feature glamour. You cannot
safely do anything else until the gate works (Phase 0) and the one real security
bug is closed (Phase 1).

---

### Phase 0 — Restore the delivery gate (foundation)

*Without this, every later phase merges blind. Highest leverage in the whole
roadmap.*

- Re-enable `pull_request:` + `push: [main]` triggers on `ci.yml`/`security.yml`
  and `push: tags: [v*]` on `release.yml`/`hitl.yml`; add **branch-protection
  required checks** on the sidecar + flutter jobs. If self-hosted runner
  capacity was the reason for disabling, gate by `paths`/`concurrency`, not by
  removing triggers.
- Make the Go suite green cross-platform: bump `go.mod` and the `setup-go` pins
  to **Go 1.26**; add `//go:build windows` to the `PhysicalDrive3` test (or
  parametrize the target by GOOS). Verified RED today.
- Make the repo **clone-and-build standalone**: consume first-party packages
  through committed git pins, with sibling `main` checkouts available only as
  local development/tool overrides. Do not add submodules, gitlinks, or vendored
  first-party mirrors.
- **Mandatory signing on the release lane**: fail the tagged build if signing
  secrets are absent (mirror the existing keyring fail-closed check), so a
  privileged helper is never shipped unsigned. Commit the production trust-
  keyring delivery into the signed pipeline and document rotation.
- Resolve the release-please-vs-CalVer conflict (pick one); rename the
  "Windows (MSI)" job to match the Inno `.exe` artifact (or move to MSIX).
- **Exit criteria:** every PR runs the full gate on Win/macOS/Linux; coverage
  floors enforced; a tagged release produces signed artifacts or fails; a fresh
  clone builds with no sibling-repo assumptions.

---

### Phase 1 — Security hardening (close the real holes)

- **P0: stop persisting plaintext passwords.** Route `first_boot.password` and
  `hardening.new_password` through the OS keychain (`flutter_secure_storage`),
  not the decisions map; add them to `redactionSessionValues()`; add a property
  test asserting `WizardState.toJson()` contains no secret keys. Add real
  username (Linux), hostname (RFC-1123), and password strength/length validation
  before provisioning; replace the length-only "strength meter."
- **Harden the Local Agent bridge** (the web/mobile backend):
  deny-by-default CORS (explicit origin allowlist, never `*`); bearer token via
  `Authorization` header only (never URL query), compared in constant time;
  refuse to start without a token; route all errors through the same
  `sanitizeErrorMessage` the IPC path uses; add a request-body size cap, SSE
  idle heartbeats, and operation-registry TTL/eviction; add **per-method
  authorization** so the browser can only reach the methods a web/mobile client
  is allowed to call.
- Stop baking the agent token into the JS bundle; fetch it via a short-lived
  pairing handshake instead.
- Close the elevated-helper **PID-reuse** watchdog hole (cookie/handshake);
  make Unix `prepareWriteTarget` actually quiesce/unmount the target before a
  raw write (parity with Windows); remove `localhost`/loopback from the
  production download allowlist; re-validate the disk at flash-commit (kill the
  TOCTOU); make SSH host-key verification fail **closed** by default.
- **Exit criteria:** secrets never reach disk/logs/bundle/JS (test-enforced);
  the agent bridge passes a focused security review; all destructive paths
  re-validate their target at commit time.

---

### Phase 2 — Platform architecture: make web & mobile first-class

- **Unify the transport-capability layer** (§1): one typed requirement
  vocabulary and capability matrix shared by desktop/web/mobile/CLI; the UI
  always explains availability per platform.
- **Keep the web stack on modern browser interop**: `package:web` +
  `dart:js_interop` is now the active browser API boundary; keep `flutter build
  web` and the Wasm dry run green as the web architecture is rebuilt.
- **Rebuild the web app to the desktop's architectural bar**: dissolve the
  823-line `main_web.dart` god-widget into Riverpod + GoRouter + tested
  screens; add cancellation/timeout/size-guards; bounded streaming firmware
  fetch; persistent device handles across steps.
- **Productionize the browser flash delegates**: real DFU `GET_STATUS` polling,
  per-write ACK/flow-control, manifest/leave + zero-length terminator, a
  `verifying` phase, `failed`-event emission, and connect-time cleanup. Test
  against fakes that *reject and stall*, not just succeed.
- **Ship the Local Agent as a first-class surface**: pairing/discovery UX,
  reconnect/backoff on the SSE stream, the hardening from Phase 1, packaging so
  a web/mobile user can install and trust it.
- **Build the mobile app** to its scoped capability set: remote fleet
  management, live monitoring/tuning (direct Moonraker over LAN), printer
  discovery via platform mDNS, Android MCU flashing via WebUSB/OTG, and
  disk-flash *delegation* to a paired agent. iOS surfaces the same minus USB.
- **Exit criteria:** web and mobile each ship from CI as signed/deployed
  artifacts; a profile flow runs end-to-end on web (MCU direct + disk via agent)
  and on mobile (manage/monitor + Android MCU); the web build targets Wasm.

---

### Phase 3 — Close every functional gap (the "no stubs" phase)

- **Build, don't defer**, each §3.2 item: real `version.compat` gating once a
  breaking sidecar/UI contract is introduced; `resume=continue`;
  `restore_from_backup`; the **S900 resume-preview UI**; checkpointed step
  continuation (+ lift the profile-lint rejection); the **debug-bundle zip pipeline**;
  the `DeckhandProductModule` task lifecycle
  (`taskStatus`/`taskCancel`/events) so agents can poll/cancel a flash; replace
  the fabricated log timestamps with real controller-emitted timestamps.
- **Profile-script runtime — decide and execute** (no middle ground): either
  build the capability-scoped isolate sandbox + static-analysis pass +
  signed-tag gating *together* and enable it, or formally cut the feature and
  remove the type-only API + the aspirational `runner.dart`/`sandbox/` doc
  references. No shipped throwing placeholder.
- **Exit criteria:** zero `UnimplementedError`/"not yet wired"/throwing-
  placeholder paths in shipped code; every declared step kind, verifier, resume
  mode, and source kind is implemented and tested, or removed.

---

### Phase 4 — Observability & operations

- **Structured logging end-to-end**: levels + a correlation id that spans
  UI→sidecar→elevated-helper, on both the Go (`slog`) and Dart sides; replace
  free-text English log strings with message codes the UI can localize.
- **Metrics**: per-operation latency/outcome, in-flight gauges, drop counters
  (the SSE bridge silently drops events today).
- **Crash reporting**: opt-in (via the existing Telescope channel) so field
  failures — bricked flashes, helper crashes — are visible without a manual
  debug bundle. Instrument real telemetry events at wizard/flash milestones.
- **Tamper-evident audit log** of destructive operations (disk writes, file
  deletes, elevation grants) suitable for a compliance trail.
- **Exit criteria:** a support engineer can reconstruct any field failure from
  correlated logs + (opt-in) crash report; destructive actions are auditable.

---

### Phase 5 — Sustainability & scalability hardening

- **Decompose the god-files** by responsibility (not by lint-ceiling): the
  `WizardController` 5-part split → real step-handler classes with encapsulated
  state (delete the ~40 dispatcher shims and the dead `_sessionAskpass`
  machinery); `handlers.go` → per-domain handler files; the 1201-line elevated
  helper and the 1000–2700-line management screens → composable units with
  business logic lifted out of widgets.
- **De-duplicate to single sources of truth**: one JSON-coercion utility, one
  byte/SHA formatter, one route↔id graph (kill the "user stranded" drift mode),
  one path-validation helper, one shared `writeManifest` struct.
- **Centralize config** (principle 3) and delete dead code (`DiscoveryBackend`,
  `WorkshopGrid`/`StatusStrip`, `powerShellDoubleQuoted`, `busTypeName`).
- **Scalability sweep** (principle 1): coalesce on-printer run-state writes;
  stream + bound the backup `find`, discovery, file transfers, and in-UI log/
  egress/preview buffers; give the RPC control plane (`jobs.cancel`/`shutdown`)
  a reserved concurrency lane; remove the marshal→unmarshal→marshal churn on the
  progress hot path; add `RepaintBoundary` to animated painters; return a
  structured error on oversized RPC lines instead of terminating the read loop;
  add resumable (HTTP range) OS-image downloads.
- **Complete i18n & accessibility**: migrate every remaining hardcoded English
  string to Slang (prioritize the destructive screens and the fatal-error
  screen); decouple UI humanization from backend wording via message codes;
  honor `MediaQuery.textScaler`; add `Semantics` to custom controls.
- **Replace the 250-line hand-rolled XZ parser and the hand-rolled YAML emitter**
  with maintained libraries (or isolate + fuzz them as the deliberate cost of
  avoiding a dep).
- **Exit criteria:** no file over an agreed size budget without justification;
  no duplicated contract; coverage gaps from §6 closed (web surface,
  `DartsshService` unit, `first_boot_setup`/`choose_os`, live discovery, the
  Invoke bridge); a documented load/scale test for fleet-sized inputs.

---

### Phase 6 — Dependency currency & release polish

- Merge the patch-level Dependabot PRs now (`xz`, `go-git`, `x/sys`); execute
  the major migrations (Riverpod 2→3, go_router 14→17, bonsoir 5→7) behind the
  now-green gate.
- Wire (or delete) the `deb`/`rpm`/`flatpak` packaging scripts; add a web-app
  deploy job; add `linux/arm64` (and consider `windows/arm64`) to the matrix.
- Fix the confirmed `ARCHITECTURE.md` drift (`os_images`→`osimg`, remove the
  `D:\git\flutter` path, author or drop `PROFILE-SCHEMA.md`); add a CI doc-link
  checker modeled on the existing `deckhand-ipc-docs --check`.
- **Exit criteria:** no dependency more than one minor behind without a tracked
  reason; docs verified in CI; every advertised platform has a build+deploy job.

## 3. Sequencing rationale

- **0 before everything**: you cannot trust any later change without an
  automatic, green, signed gate.
- **1 before 2**: the Local Agent bridge *becomes* the web/mobile backend in
  Phase 2 — it must be secure first.
- **2 before 3 for web/mobile-specific gaps**, but Phase 3's desktop gaps
  (resume modes, verifiers, debug bundle) can run in parallel with 2.
- **4 and 5 are continuous**, but called out as phases so they are funded, not
  absorbed; the observability seam (4) should land before the big refactors (5)
  so regressions are visible.
- **6 rides the green gate** — major dependency migrations are only safe once CI
  actually runs.

## 4. What not to touch

Per the audit's §8, the disk/elevation/download core (`deckhand_flash`,
`go-osimg-disks`, the elevated helper, the RPC core, the wizard's shell-safety
discipline, the release-engineering design) is already at the enterprise bar.
Refactors in Phase 5 must preserve those security invariants and their ~1:1 test
coverage — treat them as the reference standard the rest of the codebase is
brought up to, not as surface to churn.
