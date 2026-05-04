# Deckhand

A local-only desktop tool that flashes, sets up, and maintains
Klipper-based 3D printers.

Download the latest signed installer for Windows, macOS, or Linux from
the [Releases](https://github.com/CepheusLabs/deckhand-app/releases)
page, or visit [dh.printdeck.io](https://dh.printdeck.io/).

## Start here

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) - overall design, package
  layout, sidecar model, cross-platform packaging.
- [`docs/WIZARD-FLOW.md`](docs/WIZARD-FLOW.md) - screen-by-screen UX
  specification for the install wizard.
- [`docs/IPC.md`](docs/IPC.md) - sidecar JSON-RPC method catalog plus
  the supervisor's crash-recovery policy.

Cross-cutting properties, each large enough to live on its own:

- [`docs/STEP-IDEMPOTENCY.md`](docs/STEP-IDEMPOTENCY.md) - per-step
  pre-check / resume / post-check contract and the on-printer
  `~/.deckhand/run-state.json` that drives mid-execution resume.
- [`docs/PROFILE-TRUST.md`](docs/PROFILE-TRUST.md) - bundled trust
  keyring, signed-tag verification, rotation procedure.
- [`docs/DOCTOR.md`](docs/DOCTOR.md) - preflight self-diagnostic
  (CLI + `doctor.run` RPC + S10 status strip).
- [`docs/DEBUG-BUNDLES.md`](docs/DEBUG-BUNDLES.md) - what goes into
  a "Save debug bundle" zip, redaction pipeline, mandatory review
  screen.
- [`docs/HITL.md`](docs/HITL.md) - hardware-in-the-loop CI: rigs,
  scenarios, headless wizard driver.
- [`docs/RELEASING.md`](docs/RELEASING.md) - tagging, signing,
  manual smoke-test checklist.

Printer profiles (the per-printer definitions that drive Deckhand) live in
a separate repo: [CepheusLabs/deckhand-profiles][builds]. See the
[authoring guide][authoring] for how to add or modify a profile.

## What Deckhand does

Given a Klipper-based 3D printer (Phrozen Arco, Sovol Zero, Sovol SV08 Max,
…), Deckhand either (a) installs mainline Kalico or Klipper on top of your
existing OS, replacing whatever vendor firmware stack was there, or (b)
flashes a clean OS to the eMMC and installs the stack from scratch. Either
way, you end up with a printer running community-maintained firmware, a
web UI (Mainsail, Fluidd, or both), and optionally KIAUH for ongoing
tweaks. Deckhand stops where native Klipper tooling takes over for
day-to-day updates - it's a setup tool, not a lifecycle manager for
firmware releases.

## Architecture

Flutter UI (Dart) on top of a small Go sidecar for privileged local I/O.
Flutter runs the wizard and orchestrates decisions; the sidecar handles
disk flashing, shallow git clones, and HTTP fetches. See
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full layout.

## License

[AGPL-3.0](LICENSE).

[builds]: https://github.com/CepheusLabs/deckhand-profiles
[authoring]: https://github.com/CepheusLabs/deckhand-profiles/blob/main/AUTHORING.md
