# Changelog

All notable changes to Deckhand will be recorded here. Versioning is
CalVer (`YY.M.D+<commits>`); tags are `v<YY.M.D>-<commits>`. The
`## Unreleased` heading below is auto-rewritten to the resolved tag at
release time by [`scripts/stamp_changelog.sh`](scripts/stamp_changelog.sh)
(invoked from the release workflow before the tag is created).

## Unreleased — Initial release

First public release of Deckhand: a local-only desktop tool that
flashes, sets up, and maintains Klipper-based 3D printers.

### What it does

Given a Klipper-class printer (Phrozen Arco, Sovol Zero, Sovol SV08
Max, …), Deckhand either installs mainline Kalico/Klipper on top of
the existing OS, or flashes a clean OS to the eMMC and installs the
stack from scratch. Result: a printer running community-maintained
firmware, a web UI (Mainsail, Fluidd, or both), and optionally KIAUH.
Deckhand stops where native Klipper tooling takes over for day-to-day
updates — it's a setup tool, not a lifecycle manager.

### Highlights

- **End-to-end install wizard** with a screen-by-screen guided flow
  (see [`docs/WIZARD-FLOW.md`](docs/WIZARD-FLOW.md)).
- **Cross-platform desktop app** (Flutter) on Windows, macOS, Linux,
  paired with a small Go sidecar for privileged local I/O.
- **Step-idempotent execution** with on-printer run-state so an
  interrupted install resumes mid-stream instead of starting over.
- **Live-state probes**: every option screen reads what's actually on
  the printer — installed services, existing webui, KIAUH presence —
  before suggesting actions.
- **Auto-backup on every `write_file`**, with a built-in restore UI
  that handles foreign-profile backups defensively.
- **mDNS discovery** with LAN sweep + credential fallback so the
  wizard finds your printer without you typing an IP.
- **Profile trust** via a bundled keyring + signed-tag verification
  ([`docs/PROFILE-TRUST.md`](docs/PROFILE-TRUST.md)).
- **Pre-flight doctor** (CLI + RPC) for early failure detection of
  PowerShell on PATH, mDNS reachability, GitHub rate-limit headroom,
  clock skew, and elevated-helper presence
  ([`docs/DOCTOR.md`](docs/DOCTOR.md)).
- **Debug bundles** with a mandatory redaction-review screen before
  the user shares anything ([`docs/DEBUG-BUNDLES.md`](docs/DEBUG-BUNDLES.md)).
- **Hardware-in-the-loop test framework** with three reference rigs
  and a four-scenario matrix per rig
  ([`docs/HITL.md`](docs/HITL.md)).

### Quality bar going into v1

- Every `flutter test` and `go test -race -count=1 ./...` passes.
- Every Dart package passes `flutter analyze --fatal-infos`.
- Eight rounds of self-audit (Phases 1–8) + a security review pass
  resolved every CRITICAL/HIGH finding before tagging.
- Real SHA256 pins for every fetched artifact (no `*-latest` URLs).

### Known limitations

- **One-shot installer, not an update manager.** Deckhand installs
  the firmware (Klipper or Kalico), web UI (Mainsail / Fluidd), and
  optional KIAUH on a fresh or stock-keep run, then exits. Ongoing
  version bumps, plugin installs, and config syncs are owned by
  native Klipper-side tooling (KIAUH, `git pull`, package managers)
  - Deckhand does not run as a service or watch for updates.
- **Klipper and Kalico are both supported as first-class targets.**
  Vendor stacks that aren't Klipper- or Kalico-based (closed-source
  firmware, non-Klipper Marlin/RepRap variants, etc.) are out of
  scope.
- **HITL automation requires the maintainer-supplied PDU and mux
  driver scripts** — the spec is shipped, the hardware-glue layer
  is per-rig.
- **SSH host-key fingerprints prefer SHA-256 via `ssh-keyscan`.**
  dartssh2 only exposes an MD5 fingerprint in its `onVerifyHostKey`
  callback (raw host-key bytes are not surfaced). The service runs
  ssh-keyscan as a side-channel before each connect, hashes the
  returned key with SHA-256, and pins that. When ssh-keyscan is
  unavailable (older Windows hosts without OpenSSH client) it
  falls back to dartssh2's MD5 with an explicit `MD5:` algorithm
  prefix on the stored fingerprint, so the algorithm in use is
  always self-describing.
- **Linux launcher icon is a generated placeholder.** Drop a real
  256×256 PNG at [`packaging/linux/deckhand.png`](packaging/linux/deckhand.png)
  and the build script picks it up automatically; absent that, a
  minimal valid placeholder ships so AppImage doesn't render a
  broken-image launcher.

### Profiles

Per-printer profiles live in a separate repo:
[CepheusLabs/deckhand-profiles](https://github.com/CepheusLabs/deckhand-profiles).
Adding a new printer is "write a profile YAML"; see the
[authoring guide](https://github.com/CepheusLabs/deckhand-profiles/blob/main/AUTHORING.md).
