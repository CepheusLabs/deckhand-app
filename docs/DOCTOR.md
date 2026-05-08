# Doctor — preflight self-diagnostic

> The sidecar's `doctor` package
> ([`sidecar/internal/doctor/doctor.go`](../sidecar/internal/doctor/doctor.go))
> probes the host environment for the conditions Deckhand needs:
> the elevated helper is present, disk enumeration works, the
> per-OS data and cache dirs are writable, and the platform's
> elevation tool (pkexec / osascript / powershell.exe) is on the
> path. This file documents how that diagnostic is exposed to
> the UI and where it appears in the wizard.

## Surfaces

| Surface | When it runs | What it does |
|---------|--------------|--------------|
| `deckhand-sidecar doctor` (CLI) | User invokes the binary directly | Writes a human-readable report to stdout, exits 0 if every check passed. Used by [`RELEASING.md`](RELEASING.md) hardware-in-the-loop checks and by support to ask users for a quick paste. |
| `deckhand-sidecar helper-smoke` (CLI) | Developer/support validates the packaged elevated helper | Launches `deckhand-elevated-helper version` through the same events-file path used by the app and verifies `started` + `version` events. |
| `deckhand-sidecar backup-smoke` (CLI) | Developer/support validates a real read-only eMMC backup | Launches the elevated helper's `read-image` operation against a supplied disk id and leaves the resulting `.img` in Deckhand's marked `emmc-backups` root. |
| `deckhand-sidecar download-os` (CLI) | Developer/support validates OS image acquisition without driving Flutter | Downloads or reuses a verified OS image in Deckhand's managed image cache. Requires the final raw image sha256 and refuses unmanaged destinations. |
| `doctor.run` (JSON-RPC) | UI calls on launch + on demand from Settings | Returns structured results plus the same human-readable report. UI renders pass/fail badges; users who want raw output click "View report." |
| S10-welcome preflight panel | First wizard screen, every launch | Calls `doctor.run` once, shows a tiny status line: ✓ when everything passes, ⚠ when any check fails. Clicking the line expands the failure detail. |

The smoke commands create helper event/token/cancel files under the
same private temp root enforced by the elevated helper:
`<temp>/deckhand-elevated-helper`. If a smoke command reports an empty
events file, check that directory policy first; plain temp-file paths
are intentionally rejected by the helper.

`download-os` mirrors the guarded `os.download` RPC behavior for
support/debugging:

```powershell
deckhand-sidecar download-os `
  --url https://github.com/armbian/community/releases/download/26.2.0-trunk.821/Armbian_community_26.2.0-trunk.821_Mkspi_trixie_current_6.18.26_minimal.img.xz `
  --sha256 43f0e0e5cf1adf47dc56b740aea94852be14f057eb1ebececb353fee702c7b2d `
  --id armbian-trixie-minimal
```

If a cached `.img` already matches the expected sha256, the command
prints `os_image_reuse` and does not contact the network. If the cached
file is stale, it is removed and re-downloaded. The default destination
is Deckhand's managed OS-image cache, and explicit `--dest` paths are
accepted only under Deckhand-managed image roots.

## RPC contract

`doctor.run` is registered in
[`handlers.go`](../sidecar/internal/handlers/handlers.go) as a
parameter-less method:

- **Params:** none.
- **Result:**
  ```json
  {
    "passed": true,
    "results": [
      {"name":"runtime","status":"PASS","detail":"os=darwin arch=arm64 go=go1.22 sidecar=26.4.25-1731"},
      {"name":"elevated_helper","status":"PASS","detail":"/Applications/Deckhand.app/Contents/MacOS/deckhand-elevated-helper"},
      {"name":"disks_enumerate","status":"PASS","detail":"4 disk(s) enumerated"},
      {"name":"data_dir","status":"PASS","detail":"/Users/me/Library/Application Support"},
      {"name":"cache_dir","status":"PASS","detail":"/Users/me/Library/Caches"},
      {"name":"osascript_on_path","status":"PASS","detail":"/usr/bin/osascript"}
    ],
    "report": "[PASS] runtime — …\n[PASS] elevated_helper — …\n…"
  }
  ```
- **Status values:** `PASS`, `WARN`, `FAIL`. `passed` is true only
  when no FAIL is present.

The `report` string is the verbatim CLI output so a user copy-
pasting from "View report" gets identical output to running
`deckhand-sidecar doctor` themselves. Helpful for support
threads.

## Check catalog

Defined in [`doctor.go`](../sidecar/internal/doctor/doctor.go):

| Name | What it probes | Status when problem |
|------|----------------|---------------------|
| `runtime` | os/arch/Go/sidecar version | PASS always (informational) |
| `elevated_helper` | `deckhand-elevated-helper` next to the sidecar | WARN when missing (sidecar still useful for non-destructive RPCs); FAIL when the path resolves to a directory |
| `disks_enumerate` | `disks.List` returns at least one device | FAIL on enumeration error; WARN on zero disks |
| `data_dir` | `<config dir>/Deckhand/` is writable | FAIL when the directory can't be created or written |
| `cache_dir` | `<cache dir>` is writable | Same |
| `<platform>_on_path` | pkexec / osascript / powershell.exe on `$PATH` | FAIL when the OS-appropriate tool is missing |
| `mdns_resolvable` | Open a UDP socket + join the mDNS multicast group | WARN when blocked; auto-discovery on S20 will silently return zero hits otherwise |
| `github_rate_limit` | `GET https://api.github.com/rate_limit` unauthenticated | WARN below 10 requests remaining (set a PAT in Settings); WARN on network failure |
| `clock_skew` | Compare host clock to GitHub's `Date` header | WARN above 5 minutes of skew (TLS validation gets flaky); WARN on network failure |

The UI tolerates unknown check names gracefully — a newer sidecar
that adds an additional check shows it as `<status> <name>` with
the raw status name in italics rather than crashing the panel.

## Where it runs in the wizard

S10-welcome ([WIZARD-FLOW.md](WIZARD-FLOW.md) — S10) renders a
preflight strip at the bottom of the screen:

> Preflight: ✓ ready
>
> [ View report ]

When any check fails:

> Preflight: ⚠ pkexec not found on PATH (one issue)
>
> [ View report ] [ Continue anyway ]

`Continue anyway` is intentionally available — Deckhand is
useful in degraded modes (e.g. browsing profiles even without
flash capability), and the failure list is informational, not a
hard block. The actual flash screens still gate on the elevated
helper independently.

The Settings → Advanced screen has a "Run preflight" button that
calls the same `doctor.run` and shows the report inline. Useful
when a user opens the app, sees a failure on S10, runs a fix,
and wants to re-verify without restarting the wizard.

## Implementation status

- `doctor` package + CLI: implemented.
- `helper-smoke` and `backup-smoke` CLI probes: implemented. Both use
  the elevated helper's private temp-root policy for events/token/cancel
  files.
- `download-os` CLI probe: implemented. It requires a 64-hex sha256,
  writes only to Deckhand-managed image roots, and reuses existing cache
  entries only after hashing them.
- `Collect` public entry point: implemented in
  [`doctor.go`](../sidecar/internal/doctor/doctor.go).
- `doctor.run` JSON-RPC method: registered in
  [`handlers.go`](../sidecar/internal/handlers/handlers.go).
- All nine checks (runtime, elevated_helper, disks_enumerate,
  data_dir, cache_dir, `<platform>_on_path`, mdns_resolvable,
  github_rate_limit, clock_skew): implemented in
  [`doctor.go`](../sidecar/internal/doctor/doctor.go).
- `DoctorService` Dart interface: implemented in
  [`doctor_service.dart`](../packages/deckhand_core/lib/src/services/doctor_service.dart).
- `SidecarDoctorService` adapter: implemented in
  [`sidecar_doctor_service.dart`](../packages/deckhand_flash/lib/src/sidecar_doctor_service.dart).
- S10 preflight strip: implemented in
  [`preflight_strip.dart`](../packages/deckhand_ui/lib/src/widgets/preflight_strip.dart);
  wired into [`welcome_screen.dart`](../packages/deckhand_ui/lib/src/screens/welcome_screen.dart).
- Settings → "Run preflight" button: implemented in
  [`settings_screen.dart`](../packages/deckhand_ui/lib/src/screens/settings_screen.dart).
