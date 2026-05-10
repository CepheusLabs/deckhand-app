# deckhand-sidecar

Go binary that performs privileged local I/O on behalf of the Flutter UI.

## Scope

Only operations Dart can't do portably:

- `disks.list` / `disks.read_image` / `disks.write_image` / `disks.hash`
- `os.download` — HTTP fetch with progress + sha256 verify
- `profiles.fetch` — `go-git` shallow clone of the deckhand-profiles repo
- `host.info` — OS / arch / data dirs
- Lifecycle: `ping`, `version.compat`, `shutdown`

Everything else (SSH, Moonraker, mDNS, YAML parsing, UI) stays in the
Flutter side.

## Protocol

JSON-RPC 2.0 over stdin/stdout. One JSON object per line. See
[`docs/IPC.md`](../docs/IPC.md) (forthcoming) for the full method catalog.

## Build

```powershell
cd D:\git\3dprinting\installer\deckhand\sidecar
go build -o dist\deckhand-sidecar.exe ./cmd/deckhand-sidecar
go build -o dist\deckhand-elevated-helper.exe ./cmd/deckhand-elevated-helper
```

For release builds the `.github/workflows/release.yml` pipeline
cross-compiles for Windows, macOS, and Linux and packages the binaries
alongside the Flutter app.

## Elevation

The sidecar runs unprivileged. Disk flashing is delegated to a separate
`deckhand-elevated-helper` binary that Flutter launches under UAC, pkexec,
or osascript on demand. The helper owns raw block-device I/O and reports
progress back through the event-file protocol used by the Dart process
wrapper.
