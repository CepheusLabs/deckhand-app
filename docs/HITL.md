# Hardware-in-the-loop testing

> Today's [`RELEASING.md`](RELEASING.md) treats HITL as a manual
> pre-tag checklist item: "go run a stock-keep flow + a fresh-flash
> against the Sovol Zero before pushing the tag." That works for one
> active maintainer. It does not catch "Windows 11 24H2 changed disk
> enumeration" between releases, and it does not scale to multiple
> printers. This document specifies the automated HITL setup so the
> next regression in `disks.list` or the elevated helper lands in CI
> instead of in a user's bug report.

## Goal

A self-hosted runner with a real printer attached runs the most
destructive end-to-end tests on every tag, plus nightly against
main. Failure marks the build broken before a user can install
it.

## Hardware

The reference rig:

- **Host**: a small mini-PC with one of the supported OSes per
  rig (we run three rigs — one Windows 11, one Ubuntu 22.04, one
  macOS Sequoia on Apple Silicon). Each rig has the GitHub
  Actions self-hosted runner registered with labels `hitl` and
  the OS name.
- **Printer**: one Klipper-class printer per rig, connected over
  Ethernet (not WiFi — captive-portal weirdness in CI Wi-Fi
  blocks profile fetches in surprising ways). The Sovol Zero is
  the canonical test target because of its small eMMC and tight
  Python rebuild time.
- **eMMC adapter** with a USB-controllable mux (we use a custom
  tiny board built around an Adafruit USB hub IC) so the runner
  can switch the eMMC between "wired to the host" and "wired to
  the printer" without a human walking up.
- **PDU** — a network-controllable power outlet (we use a
  TP-Link Tapo P110 because of its trivial REST API; nothing in
  the test suite depends on the model). Used to power-cycle the
  printer between flow runs and to test power-loss scenarios for
  the flash sentinel work
  ([ARCHITECTURE.md](ARCHITECTURE.md) — interrupted-flash
  detection).

The full BOM and wiring diagram lives in
[`packaging/hitl/README.md`](../packaging/hitl/README.md).

## Workflow

A new GitHub Actions workflow `hitl.yml` runs:

| Trigger | What it does |
|---------|--------------|
| Tag push (`v*`) | Full matrix — all three rigs, both flows. Fails the release on any regression. |
| Daily cron (06:00 UTC) | Same matrix against `main`. Failure opens (or de-dups) a "HITL nightly broken" issue with the failing logs. |
| `workflow_dispatch` with `flow` input | Single flow on a single rig — used by maintainers to reproduce a bug. |

Each rig job runs the same script:

1. **Reset.** PDU off → wait → on. Wait for SSH on the printer's
   known IP (uses the same `DiscoveryService.waitForSsh` the
   wizard uses — see
   [WIZARD-FLOW.md](WIZARD-FLOW.md) S240).
2. **Flow A: stock-keep.** Run the install end-to-end against
   the live printer. Assertions: every step lands `completed`
   in the on-printer run-state file
   ([STEP-IDEMPOTENCY.md](STEP-IDEMPOTENCY.md)); web UI
   responds at the expected port; no sentinel files left over.
3. **Reset.** Same.
4. **Flow B: fresh-flash.** Switch eMMC mux to the host. Run
   the flash. Switch back. Wait for first boot. Assert the new
   user is created and Klipper is running.
5. **Sentinel test.** Mid-flash, the script triggers a
   simulated crash by killing the elevated helper at a known
   offset. The assertion is that `disks.list` afterwards
   includes the `interrupted_flash` field for the target disk.
6. **Snapshot test.** Run S145-snapshot
   ([WIZARD-FLOW.md](WIZARD-FLOW.md)) against a printer with a
   pre-seeded `~/printer_data/config/` containing a known
   marker file. Assert the marker survives into the host
   archive.

Each step that touches the printer or the host disk records its
duration so CI can flag drift — a stock-keep flow that's been
taking 14–16 min for a year suddenly running 28 min is the kind
of regression we want to catch before users notice.

## Artifacts

On success: nothing. The run is green.

On failure: the run uploads:

- The session log from the wizard CLI driver
  ([`packages/deckhand_hitl/bin/deckhand-hitl.dart`](../packages/deckhand_hitl/bin/deckhand-hitl.dart)
  runs the same controller without Flutter screens).
- The on-printer run-state file fetched over SSH after the
  failure.
- The sidecar's stderr capture.
- The output of `disks.list` immediately before the failure
  (always run as a probe between steps).
- A debug bundle ([DEBUG-BUNDLES.md](DEBUG-BUNDLES.md)) — the
  same one the user would have generated had they hit the
  failure manually.

## CLI driver

CI can't operate the wizard via mouse clicks. The `deckhand_hitl`
package exposes a headless CLI driver that takes a YAML scenario
file:

```yaml
# scenarios/sovol-zero/stock-keep.yaml
profile: sovol_zero
flow: stock_keep
host: 192.0.2.40
ssh:
  user: mks
  password_env: PRINTER_PASS
decisions:
  firmware: kalico
  webui: mainsail
  kiauh: true
  hardening:
    disable_makerbase_udp: true
expectations:
  step_state:
    stock_keep.firmware_clone: completed
    stock_keep.webui_install: completed
  ports:
    7125: open   # Moonraker
    80: open     # Mainsail
```

The headless driver wires the same `WizardController` as the UI,
but its adapters are real or CI-safe headless services and the
scenario YAML preloads the decisions that screens normally collect.
Failures land as scenario assertion errors with the failing step
and captured artifacts.

`packaging/hitl/scenarios/` will hold one scenario file per flow
per printer. Adding a printer to HITL is "add a rig + write a
scenario."

## Why not virtualize this?

We considered:

- **A QEMU+ARM stand-in for the printer.** Killed because the
  printer's value as a test target is precisely the things QEMU
  doesn't model: real eMMC quirks, real bus reset behaviour,
  real boot-loader interaction, real Klipper MCU subsystems.
- **A pure-software disk-flash test on the host.** Already
  exists in [`packages/deckhand_flash/test`](../packages/deckhand_flash/test).
  HITL exists to catch what those tests can't.
- **Container-only.** Doesn't exercise elevation, doesn't
  exercise USB enumeration, doesn't exercise `disks.list`
  against a real device map.

The "real hardware in CI" cost is real. The alternative is
shipping regressions that real hardware would have caught.

## Cost and uptime

Three rigs cost on the order of $1k each in hardware plus a
small ongoing colocation cost (~$30/month per rig if hosted
externally, or zero if living in the maintainer's home office).
Failure modes:

- **Printer hardware dies.** Workflow disables itself for that
  rig with a clear "rig unavailable" status. The other two rigs
  still run.
- **eMMC adapter wears out.** eMMC adapters have finite write
  cycles. The PDU+mux setup tracks adapter cycle count and
  surfaces a "swap adapter" warning at 5000 cycles.
- **Power outage at the rig.** GitHub Actions retries on its
  own; if the rig is offline for more than an hour the workflow
  marks itself skipped rather than failed.

## Implementation status

- Spec: this file.
- Workflow file: implemented at
  [`.github/workflows/hitl.yml`](../.github/workflows/hitl.yml).
  Self-hosted runners are required (`runs-on: [self-hosted, hitl,
  <os>]`); jobs queue and time out by design when no rigs are
  registered. Uses `subosito/flutter-action` to install the SDK
  and runs the driver via `dart run` (not AOT — see below).
- Headless CLI driver: **phase-2 implemented** at
  [`packages/deckhand_hitl/bin/deckhand-hitl.dart`](../packages/deckhand_hitl/bin/deckhand-hitl.dart),
  with the actual flow logic in
  [`scenario_runner.dart`](../packages/deckhand_hitl/lib/src/scenario_runner.dart).
  The driver now wires a real
  [`WizardController`](../packages/deckhand_core/lib/src/wizard/wizard_controller.dart)
  against the sidecar + a real printer, replays the scenario's
  decisions, runs `startExecution` end-to-end, and evaluates
  every assertion type:
  sidecar handshake, doctor.run, profile load, SSH connect, flow
  selection, decision application, full step execution
  (subscribing to the events stream), TCP port reachability,
  remote-file existence, on-printer run-state step statuses, and
  wall-time drift.
- AOT compilation isn't used: the driver transitively pulls
  Flutter packages (deckhand_flash, deckhand_ssh,
  deckhand_profiles), and `dart compile exe` would try to
  compile dart:ui types it never instantiates. Running via the
  Dart VM is fine for CI — Flutter SDK is on the runner anyway.
  Rationale documented in
  [`bin/deckhand-hitl.dart`](../packages/deckhand_hitl/bin/deckhand-hitl.dart).
- `deckhand_core` is now Flutter-free so the wizard controller
  itself can run in a CLI. The sole Flutter import (`rootBundle`
  for the trust keyring) moved to a shim in
  [`packages/deckhand_ui/lib/trust_keyring_asset.dart`](../packages/deckhand_ui/lib/trust_keyring_asset.dart).
- Headless service substitutes for plugins that need
  `WidgetsFlutterBinding`:
  [`HeadlessSecurityService`](../packages/deckhand_hitl/lib/src/headless_services.dart)
  replaces `DefaultSecurityService` (flutter_secure_storage),
  `StubDiscoveryService` replaces the Bonsoir-backed mDNS
  service, and `StubMoonrakerService` covers the Moonraker
  status probe. Test coverage in
  [`scenario_runner_test.dart`](../packages/deckhand_hitl/test/scenario_runner_test.dart)
  pins the security service contract (token single-use,
  fingerprint round-trip, approved-host persistence).
- Rig BOM and wiring: implemented at
  [`packaging/hitl/README.md`](../packaging/hitl/README.md);
  `reset-rig.sh` and `open-broken-issue.sh` shell out to
  vendor-specific PDU + mux drivers via abstract `pdu/<name>.sh`
  and `mux/<name>.sh` paths.
- Scenarios: full 3 × 4 matrix shipped — stock-keep,
  fresh-flash, sentinel-test, snapshot-test for linux/macos/
  windows under
  [`packaging/hitl/scenarios/`](../packaging/hitl/scenarios/).
- Reset scripts: bash + PowerShell parity. Linux and macOS rigs
  use [`reset-rig.sh`](../packaging/hitl/scripts/reset-rig.sh);
  Windows rigs use
  [`reset-rig.ps1`](../packaging/hitl/scripts/reset-rig.ps1)
  (same contract). The workflow picks the right one per
  `matrix.rig`.
- `acceptHostKey` defaults to **false** (strict pinned key) per
  scenario. Each scenario YAML opts into accept-on-first-use
  explicitly via `printer.ssh.accept_host_key: true` — used by
  fresh-flash and sentinel-test scenarios where the host key
  legitimately changes on every reflash. stock-keep and
  snapshot-test scenarios pin the key.
- `--bail-on-first-failure` actually bails. The flag is wired
  through [`ScenarioRunner.bailOnFirstFailure`](../packages/deckhand_hitl/lib/src/scenario_runner.dart);
  post-execution probes (port reachability, remote files, run-state
  comparison) skip via `shouldKeepGoing` after the first failure.
- Deckhand version is plumbed end-to-end. The workflow computes
  CalVer (or `hitl-<sha>` for non-tag runs) and passes it via
  `dart run --define=DECKHAND_VERSION=...`; the runner forwards to
  `WizardController.deckhandVersion`, which lands in the
  on-printer `~/.deckhand/run-state.json`. A failed rig run can
  be correlated to a specific release.
- PDU and mux drivers: not yet shipped — the workflow expects
  `packaging/hitl/scripts/pdu/<name>(.sh|.ps1)` and
  `mux/<name>(.sh|.ps1)` scripts on the runner host. Maintainers'
  rigs ship these alongside `rig.env` configuration.
