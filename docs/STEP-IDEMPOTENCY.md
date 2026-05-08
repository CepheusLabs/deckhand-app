# Step idempotency and on-printer run state

> Wizard state on the host (see [`wizard_state.dart`](../packages/deckhand_core/lib/src/wizard/wizard_state.dart))
> covers what the user *decided*. This document covers what
> Deckhand *did* on the printer, so a retry after a crash, a
> dropped SSH session, or a power blip resumes from the right
> point instead of starting over or running steps twice.

## Why this exists

S900 ([`progress_screen.dart`](../packages/deckhand_ui/lib/src/screens/progress_screen.dart))
already has a per-step retry button. The gap is what "retry"
means when:

- `apt-get update` succeeded but `apt-get install build-essential`
  was killed mid-package by a network drop.
- `git clone https://github.com/Klipper3d/klipper` half-completed
  and left a partial working tree.
- Klipper's Python venv build (~20 min on a slow SBC) was 80%
  done when the user closed the laptop.

Re-running blindly is sometimes safe (`apt-get install` is
idempotent), sometimes not (a second `git clone` into the same
path fails; rebuilding the venv from a partial state often
fails halfway through with a confusing error). The user
shouldn't have to think about which case they're in.

## Decision-key shape

Decisions live in `WizardState.decisions` as a flat map. Keys are
**dotted strings**, not nested maps:

```dart
{
  'firmware': 'kalico',
  'webui': 'mainsail',
  'hardening.disable_makerbase_udp': true,
  'snapshot.paths': ['cfg', 'extras'],
  'snapshot.restore_strategy': 'side_by_side',
}
```

Why dotted strings instead of nested maps?

- Stable lookup: `state.decisions['snapshot.paths']` is a one-liner;
  walking nested maps would mean special-casing missing keys at every
  level.
- Stable persistence: the wizard-state JSON file is a flat object,
  which round-trips trivially through `WizardState.fromJson`.
- Stable hashing: when the controller computes a step's input hash
  (see [`_canonicalStepInputs`](../packages/deckhand_core/lib/src/wizard/wizard_controller.dart)),
  the dotted form is already canonical — no need to recursively
  flatten.

Conventions for new decision keys:

- Single-segment for top-level user choices (`firmware`, `webui`,
  `kiauh`).
- Dotted under a screen-scoped namespace for grouped decisions
  (`hardening.<knob>`, `snapshot.<knob>`, `services.<id>`).
- Avoid colliding with existing top-level keys when adding a
  namespace; the controller doesn't enforce this, but `firmware.foo`
  next to a top-level `firmware` is confusing.

The HITL driver consumes nested YAML and flattens to this shape via
[`flattenDecisions`](../packages/deckhand_hitl/lib/src/scenario_runner.dart);
production wizards write directly via
`controller.setDecision(dottedKey, value)`.

## Two kinds of state

Deckhand persists state in two places. Keep them straight:

| Where | What | Lifetime |
|-------|------|----------|
| Host (`<data_dir>/state/wizard_session.json`) | Wizard decisions, current screen, profile id, SSH host | Until install is finished or explicitly discarded |
| Printer (`~/.deckhand/run-state.json`, written over SSH) | Which install steps have completed, with their inputs and a result hash | Persists for the life of the printer; retained as a manifest of what Deckhand did |

The host file is the source of truth for **what the user
chose**. The printer file is the source of truth for **what
got done**.

The split matters: a user might re-run Deckhand on the same
printer from a different laptop, or after a host reinstall.
The printer remembers what's already there.

## Run-state file format

```json
{
  "schema": "deckhand.run_state/1",
  "deckhand_version": "26.4.25-1731",
  "profile_id": "sovol_zero",
  "profile_commit": "8a1f3c2…",
  "started_at": "2026-04-25T14:32:11Z",
  "steps": [
    {
      "id": "stock_keep.python_rebuild",
      "started_at": "2026-04-25T14:33:02Z",
      "finished_at": "2026-04-25T14:51:49Z",
      "status": "completed",
      "input_hash": "sha256:9f…",
      "output": {
        "python_path": "/home/mks/.local/bin/python3.11",
        "version": "3.11.9"
      }
    },
    {
      "id": "stock_keep.firmware_clone",
      "started_at": "2026-04-25T14:52:01Z",
      "status": "in_progress",
      "input_hash": "sha256:7c…"
    }
  ]
}
```

- **`input_hash`** is `sha256(canonical_json(step.inputs))`.
  Inputs are the resolved profile fields the step ran with —
  e.g. for `firmware_clone`, the repo URL + ref. If the user
  jumps back in the wizard and changes the firmware ref,
  `input_hash` for that step changes, and the resume logic
  treats it as a new step (the old one stays in history).
- **`status`** is one of `in_progress`, `completed`, `failed`,
  `skipped`. `failed` records the error and exit code; `skipped`
  records the user's reason (always optional, so re-runs can
  prompt again).
- **`output`** is step-defined and consumed by later steps. Keep
  it small (paths, version strings) — never log contents,
  passwords, or anything user-identifying.

The file is written atomically (`tmp → rename`) over SSH after
every transition. Reads on session start are best-effort: a
corrupt or out-of-schema file is treated as "no run state",
matching the host wizard-state pattern in
[`wizard_state.dart:111`](../packages/deckhand_core/lib/src/wizard/wizard_state.dart:111).

## Step contract

Every step declared in a profile flow MUST satisfy:

1. **Pre-check.** A cheap probe that answers "is this already
   done?" Examples: `test -d ~/klipper && head -1 ~/klipper/.git/HEAD`
   for `firmware_clone`; `python3.11 --version` for `python_rebuild`.
   If the pre-check passes and the recorded `input_hash` matches,
   the step is skipped with `status: completed` and the recorded
   output is reused.
2. **Resume strategy.** A documented behaviour for picking up
   from an `in_progress` record:
   - `restart`: discard partial state, start over. Default for
     anything that's a few seconds of work.
   - `cleanup_then_restart`: a defined teardown command followed
     by `restart`. Used when partial state would interfere
     (e.g. `rm -rf ~/klipper.partial`).
   - `continue`: the step is internally checkpointed and can
     pick up where it left off (`apt-get install` after a network
     drop; `dd` with a recorded `seek=` offset).
3. **Post-check.** A separate probe run after the step claims
   success, to catch the "exited 0 but didn't actually do the
   thing" case. Mismatch is a `failed` status, not `completed`.

These three are declared in the profile under `flows.<flow>.steps[].idempotency`:

```yaml
- id: firmware_clone
  command: |
    git clone --depth 1 --branch {{ref}} {{repo}} ~/klipper
  idempotency:
    pre_check: |
      test -d ~/klipper/.git && cd ~/klipper && \
        git rev-parse --abbrev-ref HEAD = "{{ref}}" && \
        git remote get-url origin = "{{repo}}"
    resume: cleanup_then_restart
    cleanup: rm -rf ~/klipper.partial ~/klipper
    post_check: test -x ~/klipper/klippy/klippy.py
```

Profile-lint
([`deckhand_profile_lint`](../packages/deckhand_profile_lint))
rejects steps that omit `idempotency` unless they're flagged
`safe_to_rerun: true` (no-op steps like printing a banner).

## Resume flow

On entering S900-progress with an existing session:

1. UI calls `SshService.run(session, "cat ~/.deckhand/run-state.json")`.
   Empty file or missing → fresh run.
2. For each step in the active flow:
   - If `completed` and `input_hash` matches current inputs:
     mark green, reuse `output`, move on.
   - If `completed` and `input_hash` differs: mark yellow ("inputs
     changed"), prompt the user before re-running. Re-runs are
     normal when the user jumps back and changes a decision.
   - If `in_progress`: invoke the step's resume strategy.
   - If `failed`: present the recorded error with "retry / skip"
     buttons (current S900 behaviour, now with full context).
3. Steps not yet recorded are run in declared order.

The whole resume decision tree is computed before any command
runs and shown to the user as a "continuing from step X / re-running
steps Y / skipping Z" preview. No silent re-execution of
destructive operations.

## Step kinds and their built-in idempotency

The profile DSL recognises a handful of step kinds that
[`wizard_controller_steps.dart`](../packages/deckhand_core/lib/src/wizard/wizard_controller_steps.dart)
already implements. Each gets default idempotency wiring; profiles
can override.

| Kind | Default pre-check | Default resume | Notes |
|------|-------------------|----------------|-------|
| `apt_install` | `dpkg-query -W -f='${Status}' <pkg> \| grep -q "install ok installed"` | `restart` | Apt is idempotent; restart is safe. |
| `git_clone` | repo present + correct ref + correct remote | `cleanup_then_restart` (rm -rf the dest) | Partial clones must be wiped. |
| `service_install` | systemd unit present + enabled state matches | `restart` | systemd handles re-enable cleanly. |
| `python_venv_build` | `<venv>/bin/python -V` matches expected | `cleanup_then_restart` | Mid-build venvs are unreliable. |
| `file_replace` | sha256 of dest matches expected | `restart` | Small files; cheap to re-do. |
| `mcu_flash` | None — always re-runs on retry | `restart` | Profile authors must guard with explicit user confirmation; flashing the same firmware twice is safe but slow. |
| `snapshot_archive` | Existing archive sha256 matches the input hash | `restart` | Captures `~/printer_data/config/` (and other S145-selected dirs) into `<data_dir>/state/snapshots/<profile>-<ts>.tar.gz` via [`ArchiveService.captureRemote`](../packages/deckhand_core/lib/src/services/archive_service.dart). Decision input is `snapshot.paths` (from S145). |
| `script` (profile-shipped Dart) | Authored by the script | Authored by the script | Disabled in v1 ([ARCHITECTURE.md:380](ARCHITECTURE.md:380)). |

## Cancellation

[`WizardController.cancelExecution`](../packages/deckhand_core/lib/src/wizard/wizard_controller.dart)
is the canonical "abort this install" signal. The current step
finishes (or its `await` resolves) and then `startExecution`
throws [`WizardCancelledException`](../packages/deckhand_core/lib/src/wizard/wizard_events.dart)
before dispatching the next step.

Today the call sites are:

- HITL runner — fires when a step requests user input the
  scenario didn't pre-decide.
- Production "Cancel install" button on S900 — asks for confirmation,
  calls `cancelExecution`, and shows a canceled state once the current
  step yields.

Distinct from `StepExecutionException`: a cancellation is a
deliberate user/automation action and should produce a different
post-mortem narrative than a failed step. UIs should branch on
the type, not on the message string.

## Telemetry of a single run

When the user clicks "Save debug bundle"
([WIZARD-FLOW.md:640](WIZARD-FLOW.md:640)), the run-state file is
included alongside the session log. The redactor
([DEBUG-BUNDLES.md](DEBUG-BUNDLES.md)) treats step `output` as
needing review — it can contain home-directory paths.

## What this file does NOT cover

- **Rolling back** a partial install. Deckhand's model is
  "complete or retry"; users who need to undo a stock-keep
  conversion use the eMMC backup taken at S145 (see
  [WIZARD-FLOW.md](WIZARD-FLOW.md) — stock-config snapshot).
- **Updates after first install.** Lifecycle stays with KIAUH /
  Moonraker `[update_manager]` (see [README.md](../README.md)).
  The run-state file is install-time only.

## Implementation status

- Spec: this file.
- Run-state read/write helpers: implemented in
  [`run_state.dart`](../packages/deckhand_core/lib/src/wizard/run_state.dart),
  with `RunStateStore.load`/`.save` driving the on-printer JSON
  via SSH and `canonicalInputHash` producing stable
  `sha256:<hex>` digests over canonicalised inputs. Tested in
  [`run_state_test.dart`](../packages/deckhand_core/test/run_state_test.dart)
  (13 cases including SSH-call shape and shell-quoting safety).
- WizardController writes: implemented. `startExecution` wraps
  every step in an `in_progress` upsert + terminal `completed`/
  `failed` upsert via [`RunStateStore.save`](../packages/deckhand_core/lib/src/wizard/run_state.dart).
  Run-state load on enter so a re-run on the same printer picks
  up the prior history.
- Profile-lint rule: implemented in
  [`deckhand_profile_lint`](../packages/deckhand_profile_lint/lib/src/lint.dart).
  Steps without an `idempotency` block (and without
  `safe_to_rerun: true`) are warnings under default lint and
  errors under `--strict`, which is what `deckhand-profiles` CI
  runs. Built-in idempotent kinds (snapshot_archive,
  wait_for_ssh, os_download, verify, conditional, install_marker)
  and interactive kinds (prompt, choose_one, disk_picker) are
  exempt.
- S900 resume preview: pending — the data model is wired and
  the run-state file is now real; the UI renderer that reads it
  on enter and shows "continuing/re-running/skipping" is the
  remaining piece.
- Profile DSL `idempotency` block on existing step kinds: pending —
  authors can add it today (the lint accepts it) but the
  controller doesn't yet honor `pre_check`/`resume`/`post_check`
  to skip already-completed work. The current behaviour is
  "always re-run, log everything to the run-state file."
