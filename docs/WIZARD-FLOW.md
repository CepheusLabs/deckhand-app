# Wizard flow - what the user sees

> This document is the UX specification for Deckhand's GUI wizard. Each
> screen is numbered, named, and maps to the profile fields it consumes
> and the sidecar methods it invokes.

## Conventions used in this doc

- Every screen has a unique ID (e.g. `S10-welcome`). Deep links and analytics
  reference these.
- "Primary action" = the main right-aligned button. "Secondary action" = a
  less-prominent left or link-style button.
- "Service call" = a `deckhand_core` service interface the screen invokes.
  Production wiring hits the Go sidecar; tests wire in fakes.
- Screens are ordered by the **default** path. Conditional branches are
  called out.
- **Everything destructive asks for an explicit in-UI confirmation.**

## Navigation - progress stepper

Every wizard screen (S10 through S910) carries a **horizontal progress
stepper along the top of the window**. It shows the full path as a series
of clickable steps:

```
[ Welcome ] → [ Connect ] → [ Identify ] → [ Path ] → [ Firmware ] → [ Screen ] → [ Services ] → [ Files ] → [ Harden ] → [ Review ] → [ Install ] → [ Done ]
       ✓            ✓              ✓             ✓             ●
```

- ✓ = completed, clickable (jumping back rewinds state)
- ● = current
- Gray = future, not yet clickable

**Jumping back is the supported way to change decisions or switch flows.**
If the user clicks the "Path" step they're returned to S40 with the current
flow selection pre-highlighted; picking the other path re-generates the
downstream steps. Any decisions made past the jumped-to step are preserved
if they're still relevant, cleared if they aren't (e.g., switching from
stock-keep to fresh-flash clears the services/files decisions).

Steps are driven by the active profile's `wizard.steps_override` block if
present; otherwise Deckhand uses the default step set described below.

Forward navigation never skips steps - users advance via the primary
action on each screen. Only backward navigation uses the stepper.

---

## Top-level flow diagram

```
S10-welcome
    │
    ▼
S15-pick-printer    ← choose printer model (before any network connection)
    │
    ▼
S20-connect         ← SSH using selected profile's default credentials
    │
    ▼
S30-verify          ← run profile detection as a sanity check (warn on mismatch)
    │
    ▼
S40-choose-path     ← keep stock OS (Flow A) OR flash fresh OS (Flow B)
    │
    ├─── Flow A (stock-keep) ───→  S100..S199 + S800 + S900
    └─── Flow B (fresh-flash) ──→  S200..S299 + S100-ish post-boot + S800 + S900
```

Shared screens at the tail (`S800 review`, `S900 progress & done`) are used
by both flows.

**Picking the printer model before SSH** means Deckhand knows which profile
to load before any network activity, which credentials to try first, and
which required hosts to batch-approve. The user already knows what printer
they bought - asking upfront is more honest than trying to infer it.

---

## Shared screens

### S10-welcome

**Purpose.** First screen on app open. Set expectation, link to docs, let
the user resume an in-progress install.

**Body.**

- Deckhand logo + strapline: "Flash, set up, and maintain Klipper-based
  printers."
- One-paragraph intro.
- "Resume in-progress install" (if any) - reads from
  `state/recent_activity.json`.
- "Help & FAQ" → external link.

**Primary action.** "Start a new install" → S20-connect
**Secondary actions.** "Resume" (if applicable), "Settings".

**Adapter calls.**

- `DoctorService.run()` — the silent preflight check described in
  [DOCTOR.md](DOCTOR.md). Result drives the small status strip at
  the bottom of the screen. Failures are informational; the
  primary action stays enabled because Deckhand is still useful
  in degraded modes (the destructive flows gate on their specific
  prerequisites independently).

---

### S15-pick-printer

**Purpose.** User chooses which printer they're setting up. All subsequent
steps are driven by that profile.

**Body.**

- Header: "Which printer are you setting up?"
- Primary view: a grid of cards, one per printer profile in the registry.
  Each card shows display name, manufacturer, status badge (alpha / beta /
  stable; `stub` profiles hidden unless Settings toggle "show stubs" is on).
- Hover/tap expands a description and a link to the profile's README on
  GitHub.
- Search box above the grid for fleets with many options.
- Bottom link: "My printer isn't here →" opens the "Add a new profile"
  contributor doc in a browser.

**Primary action.** "Continue" with the selected profile.

**Adapter calls.**

- `ProfileService.fetchRegistry()` → list of (profile_id, display_name,
  status, repo, latest_tag).
- `ProfileService.ensureCached(profile_id, tag)` - shallow clone of the
  builds repo tag into the local cache.
- `SecurityService.requestHostApprovals(profile.required_hosts)` - batch
  prompts the user for network allow-list approval before we hit any of
  the hosts the profile declares.

**Notes.**

- If the user jumps back here from a later screen (via the top stepper)
  and changes printer, Deckhand clears all downstream decisions and
  disconnects the current SSH session if any.

---

### S20-connect

**Purpose.** Establish an SSH session to the printer using the chosen
profile's default credentials.

**Body.** Three sub-panels, user can pick any:

1. **Auto-discover** (default)
   - Shows a list of Moonraker instances found on the LAN via mDNS
     (`_moonraker._tcp.local`).
   - Each entry: hostname, IP, Moonraker port.
   - "Refresh" button re-scans. First scan runs on entry.
2. **Manual IP/host**
   - Text field for host, optional port.
3. **Use a saved connection**
   - List of connections from `state/connections.json`, filtered to
     previous sessions for the same `profile_id`.

**Primary action.** "Connect" - tries the profile's `ssh.default_credentials`
in order. If saved connection is used, tries saved credentials first.

**Adapter calls.**

- `DiscoveryService.scanMdns(timeout: 5s)` - populates list.
- `SshService.tryDefaults(host, profile.ssh.default_credentials)` on connect.
- If defaults fail, a modal prompts for user/password/key.

**Error states.**

- Host unreachable → retry / change IP.
- Auth failed with all defaults → prompt for credentials, with "test
  connection" button.
- Host key mismatch → hard stop, show fingerprint, explain MITM implication.

**Notes.**

- SSH sessions are resumable - if the app loses the connection mid-flow,
  next screen re-establishes silently.
- User's password is stored in OS keychain only if they check "Remember"
  (unchecked by default).

---

### S30-verify

**Purpose.** Run the selected profile's `stock_os.detections` as a sanity
check against the actual printer we just connected to.

**Body.** A short checklist showing each detection probe with a pass/fail
indicator and the exact check being performed.

- If all `required: true` detections pass → screen auto-advances after a
  brief "Verified" flash.
- If any required detection fails → banner: "This doesn't look like a
  {{profile.display_name}}. We ran these checks and some didn't match."
  Shows the failing checks with explanations. Two buttons:
  - "Go back and pick a different printer" → S15
  - "Continue anyway" (second-level warning modal required) → S40
- On partial match (required pass, optional fail) → briefly notes the
  partial confirmation and advances.

**Primary action.** Auto-advance on full match; otherwise "Continue
anyway" or "Back."

**Adapter calls.**

- `SshService.run(session, detection.<probe>)` for each detection in the
  profile. Results streamed back for the checklist.

**Notes.**

- This screen is skippable via settings ("Skip verification") for power
  users who already know their printer matches the profile.

---

### S40-choose-path

**Purpose.** Flow A vs. Flow B decision.

**Body.**

Two large cards:

1. **Keep my current OS**
   - "Reuses the OS already on your printer; installs OSS firmware in place."
   - Shows: "Detected OS: Armbian 22.05 Buster (Python 3.7)."
   - Note if profile requires Python rebuild: "⚠ Your OS has Python 3.7;
     firmware needs 3.9+. Deckhand will build Python 3.11 from source
     (~20 min on this board)."
   - Eligibility check based on profile `firmware.requires_python_rebuild_if`.
2. **Flash a new OS**
   - "Wipes the eMMC and installs a clean Armbian image."
   - Shows: "Recommended image: {{os.fresh_install_options[0].display_name}}."
   - Warning: "This requires an eMMC-to-USB adapter (or boot-from-SD)."

**Primary action.** "Continue" with the selected card.

**Adapter calls.** None at this screen - just reads profile info.

---

## Flow A - stock keep

Profile-driven questions. The wizard walks the `stock_os.services` and
`stock_os.files` inventories and asks per-item decisions.

### S100-firmware

**Purpose.** Choose Kalico vs. Klipper.

**Body.** Two cards (or more, if profile declares more choices) populated
from `firmware.choices[]`. Each card shows:

- Display name
- Short description (from profile)
- Repo URL + ref
- Python minimum
- "Recommended" badge if `recommended: true`

If the user's OS has Python < `python_min` for any choice, that card shows
a banner: "Will build Python 3.11 from source (~20 min)."

**Primary action.** "Continue" with selected firmware.

**Adapter calls.** None.

---

### S105-webui

**Purpose.** Choose which web interface(s) to install.

**Body.** Three cards + one checkbox:

- **Mainsail** - "Fast, opinionated, darker aesthetic. Recommended if you
  want a focused UI optimized for print day-to-day."
- **Fluidd** - "Extensible, dashboard-oriented, lighter aesthetic.
  Recommended if you want more customization and file-browser-first."
- **Both** - "Install both and let yourself choose per session. They
  coexist on different ports."
- **[ ] Neither - I'll handle web UI myself** (advanced).

Each card shows the upstream GitHub link, the default port, and the asset
name shipped in that project's releases.

**Primary action.** "Continue" with the selection.

**Adapter calls.** None at this screen; decision is recorded for execution.

**Notes.**

- **Stock-keep flow:** detects whether Mainsail/Fluidd are already
  installed and pre-selects them with an "already installed, will update"
  badge.
- Profile can declare `stack.webui.force_choice` to pin one option and
  skip this screen on specific hardware (rarely needed).

---

### S107-kiauh

**Purpose.** Offer to install KIAUH for ongoing stack management.

**Body.**

- Header: "Install KIAUH?"
- Explainer paragraph: "KIAUH is the Klipper Installation And Update
  Helper - an interactive menu you run over SSH (`./kiauh/kiauh.sh`) that
  lets you install, update, remove, and troubleshoot every piece of the
  Klipper stack (Klipper/Kalico, Moonraker, Mainsail, Fluidd, crowsnest,
  more). It's the de-facto community tool for fleet maintenance and is
  what most Klipper tutorials reference. Deckhand handles first-install;
  KIAUH handles ongoing tweaks you might want later."
- Two options:
  - **Install KIAUH** (recommended) - adds `~/kiauh` to the printer.
  - **Skip** - you can install it later with `git clone
    https://github.com/dw-0/kiauh.git`.
- A "What KIAUH can do for you" expander with 4-5 bullet examples
  (install an additional Klipper instance, swap branches, reinstall
  Moonraker, manage timelapse, etc.).

**Primary action.** "Continue" with the selection.

**Adapter calls.** None; decision is recorded for execution.

---

### S110-screen

**Purpose.** Choose the screen daemon.

**Body.** Cards from `screens[]`. Each card shows name, description,
status (alpha/beta/stable), and any dependencies (e.g. voronFDM needs
phrozen_master as stub).

Supported screen sources:

- Omitted `source_kind` or `source_kind: bundled` uses the screen payload
  bundled with the selected profile. `source_path` and optional
  `install_script` must be profile-local paths such as `./screens/arco` or
  repository-shared paths such as `shared/screens/arco`; absolute paths and
  parent-directory traversal are rejected by the linter and runtime.
- `source_kind: restore_from_backup` is not supported by the current
  runtime. The profile linter rejects tagged profiles that declare it until
  the schema defines which backup artifact should be restored and how it
  should be applied.

**Primary action.** "Continue".

**Adapter calls.** None for the supported bundled-screen path.

---

### S120-services (per-service questions)

**Purpose.** Walk through every vendor service declared in
`stock_os.services[]` that has a `wizard:` block (skip those with
`wizard: none`).

**Body.** One question per screen (don't bundle). Each screen renders:

- Big question text (from `wizard.question`).
- Helper text paragraph (from `wizard.helper_text`).
- Options as a radio group (from `wizard.options[]`).
- "Recommended: X" badge on the default option.
- Side panel: "What this service does" - expanded description from
  `roles[]` if present.

**Per-service default** is resolved by evaluating
`wizard.default_rules[]` against earlier decisions (e.g., "if screen is
voronFDM then stub phrozen_master"). User can override.

**Adapter calls.** None during questions; decisions are accumulated in
wizard state.

---

### S140-files (leftover files batch)

**Purpose.** Per-item checkboxes for `stock_os.files[]`.

**Body.** A single screen with a scrolling list of checkboxes. Each item:

- Checkbox (default state from profile's `default_action`)
- Display name
- Helper text
- Resolved paths that will be deleted

Two buttons at the bottom: "Select all" / "Deselect all" for quick override.

**Primary action.** "Continue".

---

### S145-snapshot (stock config snapshot, Flow A only)

**Purpose.** Capture the printer's hand-edited config files
**before** the install rewrites them. Without this screen the
single biggest reason users avoid Flow A is "I'll lose my
printer.cfg tweaks." With it, users tick a few boxes and Deckhand
preserves the work — silently or as a side-by-side diff after
install.

**Body.**

- Heading: "Save your current configuration."
- Helper text: "Before we install Klipper from upstream we'll
  archive these directories from your printer. They'll be
  restored side-by-side after install so you can copy any tweaks
  you want to keep."
- Per-path checkbox list driven by
  `profile.stock_os.snapshot_paths[]`. Defaults to *all checked*
  — opting **out** is the deliberate action because a missed
  config file is a worse user experience than an unwanted backup.
  Common entries:
  - `~/printer_data/config/` — printer.cfg + macros.
  - `~/printer_data/database/` — Moonraker history (small, often
    skipped).
  - `~/klippy_extras/` — third-party extras users dropped in by
    hand.
  - `~/.config/<vendor>/` — vendor-specific slicer presets when
    the profile knows where to look.
- Side panel: a live size estimate ("Selected paths: ~28 MB"),
  recomputed when the user toggles boxes. The probe runs
  `du -sk` over each path on the printer once and caches the
  result for the screen.
- Bottom: a single "Restore strategy" radio:
  - **Side-by-side** (default) — archive is unpacked into
    `~/printer_data.stock-2026-04-25/` after install; the user
    decides what to merge.
  - **Auto-merge non-conflicting files** — files that don't exist
    in the new install are copied in directly; conflicting files
    land in the side-by-side dir for manual review. Opt-in
    because what counts as "conflict" depends on profile
    knowledge.

**Primary action.** "Snapshot and continue." Disabled until at
least the size probe finishes, so users see a moment of "we're
checking your printer" before the long-running tar.

**Adapter calls.**

- `SshService.duPaths(session, paths)` — populates the size
  estimate.
- `ArchiveService.captureRemote(session, paths, archivePath)` —
  streams a `tar -czf -` over SSH into a host-local file under
  `<data_dir>/state/snapshots/<profile>-<ts>.tar.gz`. The archive
  hash is recorded in the session log.

  Wire format note: `SshService.runStream` is line-oriented (UTF-8
  decoded, split on `\n`). Raw binary tar bytes can't survive that
  — they'd contain arbitrary 8-bit values. The implementation
  wraps the stream in `tar | base64 | fold -w 76` on the printer
  side, which yields a steady ~57-byte chunk per line and matches
  the MIME / PEM convention. The host decodes each line back to
  bytes. A future `ArchiveService` impl that uses a binary-safe
  transport (raw exec channel, SFTP-only) can drop the wrapper.

  Restore reverses the flow: the host uploads the archive via
  SFTP to a `/tmp/deckhand-restore-<ts>.tar.gz` path on the
  printer, runs `tar -xzf` against the uploaded file, then
  removes the tmp. The previous design embedded the entire
  base64 archive in a single shell command line — that exceeds
  POSIX `ARG_MAX` (~128 KiB) for any real-world snapshot.

**Notes.**

- The archive lives in the host's data dir, not on the printer.
  Users who reflash the printer from another machine can move
  the archive over; Settings → Snapshots lists every captured
  archive with its session id, printer hostname, and timestamp.
- This screen never appears in Flow B (fresh flash): a clean
  flash has nothing to preserve. Users who want a pre-flash
  backup of the *whole disk* use the Manage view's Backup tab
  ([WIZARD-FLOW.md](WIZARD-FLOW.md) — manage view).
- If the SSH connection drops mid-archive the operation aborts
  cleanly and the user sees a retry prompt; partial archives are
  deleted by the host before retry to avoid confusing later
  restores. The on-printer side uses `tar` with no temp file —
  output streams directly to the SSH channel — so a kill
  mid-stream doesn't leave junk on the printer.
- The post-install side-by-side restore is part of the S900
  step list as a `kind: snapshot_restore` step. Failure of the
  restore is non-blocking (the install itself succeeded); the
  archive stays on the host so the user can attempt restore
  manually.

---

### S150-hardening (optional security items)

**Purpose.** Opt-in hardening suggestions.

**Body.** Same checkbox list style as S140 but defaulting to **unchecked**.
Items driven by profile; common ones include:

- Disable makerbase-udp
- Disable makerbase-net-mods (after wifi is set)
- Fix 3-way time-sync conflict
- Change default SSH password

If "change default SSH password" is selected, a sub-field shows up inline
(new password + confirm, with strength indicator).

---

### S160-printer-specific extras

**Purpose.** Run any `wizard.extra_steps[]` declared in the profile
(e.g., "Flash ChromaKit firmware?" for the Arco).

**Body.** One screen per extra step. Rendered per its declared `kind`
(prompt, choose_one, etc.).

---

## Flow B - fresh flash

### S200-flash-target

**Purpose.** Pick which disk to flash. Show a confirmation of "we're about
to wipe this disk."

**Body.**

- Top: "Connect the printer's eMMC to your computer via a USB adapter."
- Table of local disks (from `FlashService.listDisks()`).
  - Columns: Name/model, bus (USB/NVMe/SATA), size, partitions, "removable".
- Disks that don't match `hardware.sbc.emmc_size_bytes` ±10% are dimmed
  with "doesn't match expected eMMC size" note - users can still override
  with an extra confirmation.
- Refresh button.

**Primary action.** "Use this disk" (enabled only when a disk is selected).

**Adapter calls.**

- `FlashService.listDisks()` (on mount + on refresh).

---

### S210-choose-os

**Purpose.** Pick the OS image to flash.

**Body.** Cards from `os.fresh_install_options[]`:

- Name, recommended badge, approximate size, notes.
- Each card has a "Show URL + SHA256" expander.
- Bottom section: "Use a local image file" - file picker for users who
  downloaded ahead of time.

**Primary action.** "Continue".

---

### S220-flash-confirm

**Purpose.** Final confirmation before writing.

**Body.** Big warning card with the target facts prominently displayed:

- "About to write **{{image_name}}** to **{{disk_model}}** ({{disk_size}})."
- "This will erase EVERYTHING on that disk. No undo."
- Two check boxes (both must be ticked to enable the action):
  - [ ] I have backed up anything I need from this disk.
  - [ ] I understand this cannot be undone.
- Disk summary panel at the bottom: model, size, bus (USB), partitions with
  filesystem types - so the user sees once more what they're about to wipe.

**Primary action.** Red-styled button "Wipe and flash" - enabled only when
both boxes ticked. Clicking opens a final modal:

> ### Wipe {{disk_model}}?
>
> This action is irreversible. Confirm to proceed.
>
> [ Cancel ]   [ Yes, wipe this disk ]

Default focus on `Cancel`; `Enter` does not trigger the wipe.

**Adapter calls.**

- `SecurityService.issueConfirmationToken(op: "flash", target: disk_id)` -
  60s single-use token issued after the modal is confirmed.

---

### S230-flash-progress

**Purpose.** Show the flash op.

**Body.**

- Big progress bar (bytes written / total bytes).
- Secondary line: "Writing at 22.4 MB/s - ETA 2:14".
- Log window showing the last N log lines.
- "Abort" button (requires extra confirmation - aborting mid-write leaves
  the disk in an unknown state).

**Adapter calls.**

- `OsService.download(url, sha256, dest)` if not cached.
- `FlashService.writeImage(imagePath, diskId, confirmationToken)` -
  returns a `Stream<FlashProgress>`.

After write: automatic integrity check (`disks.hash` of the written disk
vs. source image hash). If mismatch → S231-flash-verify-failed.

---

### S231-flash-verify-failed (error branch)

**Body.** "Wrote successfully but verification failed." Guidance:
try another adapter, check the USB cable, re-flash.

---

### S240-first-boot-prompt

**Purpose.** Instruct user to put the eMMC back and power on.

**Body.**

- "Flash successful. Now:"
- Step 1: Unplug the USB adapter.
- Step 2: Put the eMMC module back in your printer.
- Step 3: Power on.
- Step 4: "Deckhand will poll for SSH access - wait up to 10 minutes."
- Live status line: "Waiting for SSH at 192.168.1.50:22…"

**Adapter calls.**

- `DiscoveryService.waitForSsh(host: detected_or_manual, timeout: 600s)`
  - polls via TCP connect then `ssh -T`.

---

### S250-first-boot-setup

**Purpose.** Create the expected user, update apt, set hostname.

**Body.** Form with defaults pulled from `ssh.recommended_user_after_install`:

- Username: `mks` (editable)
- Password: prompt, confirm, strength meter
- Hostname: printer name suggestion
- Timezone: system default or override

Defaults match the stock convention so users can mix new-OS printers with
stock-OS ones without credential churn.

**Primary action.** "Create user and continue."

**Adapter calls.**

- `SshService.run(…)` for each provisioning command.

---

### S260..S280-stack-install

Same base steps as Flow A post-firmware: install Kalico/Klipper, install
Moonraker + web UI, link ChromaKit extras, install screen, flash MCUs,
run verifiers.

Flow B **skips** service/file cleanup questions (nothing to clean up on a
fresh install).

---

## Shared tail screens

### S800-review

**Purpose.** Last chance to back out. Show every decision made.

**Body.** Collapsible sections per wizard phase:

- Firmware: Kalico (main branch) → /home/mks/kalico
- Screen: arco_screen (bundled from profile)
- Services: frpc → remove, phrozen_master → stub, …
- Files: 7 items selected for deletion
- Hardening: "Disable makerbase-udp" enabled
- MCU flashes: main (STM32F407 via USB DFU), toolhead (STM32F103 via BOOT0+RESET, manual)

Each row links back to the screen it came from for last-minute edits.

Bottom: "Everything here will be executed in order. You can stop between
steps but partial state may remain."

**Primary action.** "Start install" (blocked until user re-ticks a
confirmation checkbox).

---

### S900-progress

**Purpose.** Real execution, step by step.

**Body.** Split view:

- Left: checklist of steps from `flows.<selected>.steps[]`. Current step
  highlighted with a spinner; completed steps get a green check; failed
  steps get a red X with a "retry" button.
- Right: a tabbed pane with two views — **Log** (default, live log
  stream) and **Network**. The Network tab subscribes to
  `SecurityService.egressEvents` and renders one row per request:
  host, operation label, status, bytes. Active requests show a
  spinner; completed rows expand on click to reveal the full URL
  and timestamps. The tab badge shows a count of in-flight
  requests so the user can switch to it without watching the log
  scroll past. Users uncomfortable with what they see can pause
  the install (the "Pause after current step" button) and revoke
  hosts in Settings.
- Top: overall progress bar (derived from steps completed).

Each step sends a notification when it starts, emits progress for
long-running steps, and signals completion with a summary.

**Destructive-step confirmation pauses.** Any step declared with
`kind: confirm_before_run` in the profile (or detected automatically: all
steps that write outside `~/printer_data/` or replace `~/klipper`) pause
before executing. The UI shows a modal summarizing what's about to happen:

> ### Replace `~/klipper` with Kalico?
>
> The existing directory will be moved to
> `~/klipper.stock.2026-04-17` before the new contents are installed.
>
> [ Cancel install ]   [ Continue ]

Default focus on `Continue` for these (vs. `Cancel` on the nuclear flash
confirm) because the user already ticked through S800 review; this is a
second-chance last look, not a first-time warning.

**Adapter calls.** Many. See `IPC.md` for the method map of step kinds.

**On failure:**

- Step shown red with error detail.
- "Retry" re-runs that step.
- "Skip" available only for steps marked `kind: optional`.
- "View log" opens the full session log.
- "Save debug bundle" tars logs + profile + decisions into a `.zip` for
  support.

**On success:**

- All checks green.
- Primary action: "Finish" → S910-done.

---

### S910-done

**Purpose.** Celebrate + point at next steps.

**Body.**

- "Setup complete."
- Summary: printer name, firmware, web UI URL (clickable).
- "Test print" CTA → launches the user's browser to `http://<host>:<port>/`.
- Links to: restore-from-backup (if ever needed), "Run setup again on
  another printer", docs.

---

## Error and recovery screens

These can appear at any point:

- **E-net-unreachable** - "Can't reach that printer. Check your network."
- **E-ssh-auth** - "We couldn't log in. Enter credentials manually."
- **E-host-key-mismatch** - Hard stop. Explanation + "Clear stored
  fingerprint" button.
- **E-sidecar-missing** - "Helper binary missing; please reinstall Deckhand."
- **E-disk-io** - During flash; surfaces the OS error + suggests retry.
- **E-profile-fetch-failed** - "Can't fetch profile from deckhand-profiles.
  Check internet or provide local path."
- **E-unknown** - generic with "Save debug bundle" button.

Each error screen has a "Back" option (to the previous non-error screen)
and "Quit" (save state to `state/recent_activity.json` so S10 can resume).

---

## Settings (accessible from header bar)

- **General** - default flash verification behavior, retain debug bundles
  after success (yes/no), Deckhand check-for-updates cadence.
- **Connections** - saved printer endpoints, manage (rename, delete,
  set fingerprint).
- **Profiles** - installed profile cache versions, "check for updates",
  "use edge (main branch) for profile X" toggle.
- **Appearance** - theme (system/light/dark), density (compact/comfy).
- **Advanced** - GitHub API token (for unauthenticated rate-limit relief),
  allow-listed hosts (network egress), sidecar path override.

---

## Out-of-band screens for ongoing maintenance

The wizard is the install flow. Deckhand also has a **manage** view shown
when the user opens the app with an already-configured printer. Scope is
intentionally narrow - anything Klipper's / Kalico's / Moonraker's own
update paths already handle stays with those native tools.

| Tab | What it does | Why Deckhand owns it |
|-----|--------------|----------------------|
| **Printer status** | Moonraker state, current job if any, quick links to the web UI | read-only, mirrors the web UI's summary so user doesn't switch apps just to check |
| **Backup** | `dd` the eMMC to a local `.img`, verify SHA256 | No native Klipper/Kalico/Moonraker tool does raw-disk backups. Essential before stock-keep conversions and nice to have otherwise. |
| **Restore from backup** | Reverse of fresh-flash using a previously-captured `.img` | Same reasoning as backup. |
| **Flash MCU firmware** | Currently unavailable until profile metadata defines a concrete flash transport contract | Deckhand should eventually own this because MCU flash commands are hardware-specific and risky, but the app must not pretend a build-only step reflashed hardware. |
| **Re-run setup wizard** | Jump back to S40 (choose path) preserving known printer identity | Handles reconfigure / repair / migrate. |

**Explicitly NOT in Deckhand's manage view:**

- Update Kalico / Klipper → `git pull` + restart via Moonraker's
  `[update_manager]` panel in the web UI, or via KIAUH.
- Update Moonraker → same, native `[update_manager]`.
- Update Fluidd / Mainsail → same.
- Update KIAUH itself → KIAUH has its own updater.

This keeps Deckhand's ongoing surface small and avoids re-inventing update
flows that work well with their native homes.

---

## Responsiveness & accessibility

- **Min width 1024px** for comfortable wizard display. Deckhand's desktop
  targets don't go narrower than that in practice.
- **Keyboard navigation** - Tab ordering defined per screen; Enter submits
  the primary action; Esc goes back.
- **Screen reader** - each screen declares a title and a semantic outline
  of its sections.
- **Localization** - Slang i18n keys. English at v1; add locales
  incrementally.

---

## Telemetry

None at v1. All logs stay local. If ever added, behind an explicit opt-in
in Settings with a "see what's sent" button that opens the outbound JSON.
