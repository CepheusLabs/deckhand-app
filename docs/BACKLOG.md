# Backlog

## Open Follow-Ups

- Implement per-MCU flashing once profile metadata includes a concrete
  flash command/transport contract. The Manage view intentionally labels
  this as unavailable instead of pretending a build-only step flashed
  hardware.
- Implement screen `source_kind: restore_from_backup` when the profile
  schema defines which snapshot artifact should be restored and how it
  should be applied. Bundled screen payloads are supported today.
- Add hardware-backed tests for mDNS discovery and profile sidecar loading.
  Current coverage exercises pure parsing, registry enrichment, and wizard
  behavior without requiring another printer or a live sidecar process.
