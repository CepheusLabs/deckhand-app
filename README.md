# Deckhand

A local-only desktop tool that flashes, sets up, and maintains
Klipper-based 3D printers.

> **Status: design phase.** No usable binaries yet. Architecture and
> specification docs are the deliverable at this stage.

## Start here

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — overall design, package
  layout, sidecar model, cross-platform packaging.
- [`docs/WIZARD-FLOW.md`](docs/WIZARD-FLOW.md) — screen-by-screen UX
  specification for the install wizard.

Printer profiles (the per-printer definitions that drive Deckhand) live in
a separate repo: [CepheusLabs/deckhand-builds][builds]. See the
[authoring guide][authoring] for how to add or modify a profile.

## What Deckhand does

Given a Klipper-based 3D printer (Phrozen Arco, Sovol Zero, Sovol SV08 Max,
…), Deckhand either (a) installs mainline Kalico or Klipper on top of your
existing OS, replacing whatever vendor firmware stack was there, or (b)
flashes a clean OS to the eMMC and installs the stack from scratch. Either
way, you end up with a printer running community-maintained firmware, a
web UI (Mainsail, Fluidd, or both), and optionally KIAUH for ongoing
tweaks. Deckhand stops where native Klipper tooling takes over for
day-to-day updates — it's a setup tool, not a lifecycle manager for
firmware releases.

## Architecture

Flutter UI (Dart) on top of a small Go sidecar for privileged local I/O.
Flutter runs the wizard and orchestrates decisions; the sidecar handles
disk flashing, shallow git clones, and HTTP fetches. See
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full layout.

## License

[AGPL-3.0](LICENSE).

[builds]: https://github.com/CepheusLabs/deckhand-builds
[authoring]: https://github.com/CepheusLabs/deckhand-builds/blob/main/AUTHORING.md
