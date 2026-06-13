# Deckhand → forge migration

> **Status:** ✅ **COMPLETE** — shipped to `main` 2026-06 (commits `a5a2b47` / `ef3a8d2`).
> `DeckhandTokens`/`DeckhandTheme` and the bespoke widget fork are gone from the
> tree; `forge` + `forge_wizard` are pinned git dependencies. This document is
> retained as the migration record; the checklists below are all done.
> **Type:** greenfield rebuild — **no users, no cutover, no compatibility layer.**
> **Owner:** evan@cepheuslabs.com

Deckhand's UI (`packages/deckhand_ui`) is currently a **fork** of the shared
`forge` design system: it has zero `package:forge` imports and instead ships
its own `DeckhandTokens`, `DeckhandTheme`, `DeckhandStepper`/
`DeckhandWizardStepper`, IBM Plex fonts, and ~17 bespoke widgets that
duplicate forge components. The other family apps (anvil, printdeck,
colorwake) consume forge directly.

This migration deletes the fork and rebuilds Deckhand's UI idiomatically on
forge, the way it would have been built if forge had existed first.

## Principles

1. **Adopt forge wholesale.** Forge's palette, density, type, and components
   are the source of truth. We do **not** preserve Deckhand's OKLCH values,
   its extra border gradations, or its current look. The app will look
   different (forge violet, Geist). That is intended.
2. **No compatibility shim.** `DeckhandTokens`/`DeckhandTheme` are deleted,
   not bridged. Every call site is rewritten to read forge directly.
3. **Delete, don't re-skin.** Where forge ships a component, the bespoke
   Deckhand widget is deleted and call sites use the forge component.
4. **Keep only genuine Deckhand identity:** `DeckhandLogo`, `WizardNavMap`
   (routing data), the 29 screens, and `deckhand_core` domain logic.
5. **Forge stays out of `deckhand_core`.** `deckhand_core` is pure-Dart (the
   HITL driver compiles against it). Only `forge_wizard` (also pure-Dart)
   may be added there; the Flutter `forge` package goes in `deckhand_ui` +
   `app` only.

## Locked decisions

| Topic | Decision |
|---|---|
| Fonts | **Geist + GeistMono** (drop IBM Plex assets) |
| Palette | forge `ClBrandColors`, violet accent (`ClAccentPalette.violet`) |
| Density | `ClDensity.compact` (matches anvil) |
| `info`/`accentDim`/`accentBright` | **dropped** → forge semantics (`primary`, state layers, `ClShadows.glow`) |
| Wizard state | `deckhand_core` adopts `forge_wizard` (`ForgeWizardState`/`ForgeWizardFlowProcess`) |
| forge wiring | pinned git dependencies; no submodules or nested first-party checkouts |
| Shell | unchanged — already on `printdeck_product_platform.ProductShellFrame` |

## Wiring (Phase 0)

Deckhand consumes first-party packages the same way as the rest of the
workspace: upstream code lives in sibling `main` checkouts for development, and
Deckhand's manifests commit explicit git pins for reproducible clean clones.
Do not add `.gitmodules`, gitlinks, or nested first-party mirrors.

| Package | Add |
|---|---|
| `packages/deckhand_ui/pubspec.yaml` | `forge` git pin to `CepheusLabs/forge` |
| `app/pubspec.yaml` | `forge` git pin to `CepheusLabs/forge` |
| `packages/deckhand_core/pubspec.yaml` | `forge_wizard` git pin to `CepheusLabs/forge`, path `packages/forge_wizard` |

Remove the IBM Plex `fonts:` block from `deckhand_ui/pubspec.yaml`. No
`dependency_overrides` required (riverpod ^2.6.1 / go_router ^14 are
compatible with forge).

## Token map (`DeckhandTokens.X` → forge)

Read via `context.brandColors` (colors), `context.radii` (radii),
forge text styles + `buildClTheme` (type/fonts).

### Colors → `context.brandColors`

| Deckhand | forge | Deckhand | forge |
|---|---|---|---|
| `ink0` | `bg` | `text` | `ink` |
| `ink1` | `bgAlt` | `text2` | `ink2` |
| `ink2` | `surface` | `text3` | `ink3` |
| `ink3` | `surface2` | `text4` | `ink4` |
| `ink4` | `surface3` | `accent` | `primary` |
| `line` | `borderStrong` | `accentFg` | `onPrimary` |
| `lineSoft` | `borderSubtle` | `accentSoft` | `selectedBg` |
| `rule` | `borderStrong` | `gridLine` | `canvasGrid` |
| `ok` | `good` | `warn` | `warn` |
| `bad` | `bad` | | |

**Dropped tokens (no forge equivalent — rewrite per intent):**
- `info` → `primary` (informational emphasis) or `statusIdle` (literal blue).
- `accentDim` → `primary` + `hover`/`hoverStrong` state layer.
- `accentBright` → `selectedBorder`, or `ClShadows.glow(primary)` for glows.

### Radii → `context.radii` (exact)
`r1`→`xs` (2) · `r2`→`sm` (4) · `r3`→`md` (6) · `r4`→`xl` (10)

### Type / fonts
Stop hand-setting `fontSize:`/`fontFamily:`. Use forge text styles:
`context.clTitleLarge`, `context.clBodyMedium`, `context.clBodySmall`,
`context.clLabelSmall`, and `context.dataSmall`/`dataTiny`/`labelTechnical`
for monospace. `buildClTheme` provides the base `TextTheme` in Geist.

## Widget map (`deckhand_ui` → forge)

| Deckhand widget | Action | forge |
|---|---|---|
| `wizard_scaffold` | replace | `ClWizardPageScaffold` |
| `deckhand_wizard_stepper` | delete | `ClWizardPhaseStepper` |
| `deckhand_theme` + `deckhand_tokens` | delete | `buildClTheme` + `context.brandColors` |
| `theme_toggle_button` | delete | `ClThemeToggle` |
| `danger_card` | delete | `ClDangerPanel` |
| `deckhand_panel` | delete | `ClPanel` |
| `deckhand_prompt_card` | delete | `ClPromptCard` |
| `selection_card` | delete | `ClSelectionCard` |
| `dashed_divider` | delete | `ClDashedDivider` |
| `id_tag` | delete | `ClIdTag` |
| `tick_rule` | delete | `ClTickRule` |
| `wizard_log_view` | delete | `ClLogView` |
| `wizard_progress_bar` | delete | `ClProgress` |
| `deckhand_loading` | delete | `ClLoadingState` / `ClTechnicalLoaders` |
| `equal_height_grid` | delete | `ClEqualHeightGrid` |
| `grid_background` / `workshop_grid` | delete | `ClGridBackground` / `BlueprintBackground` |
| `status_pill` / `status_strip` / `preflight_strip` | delete | `ClStatusChip` / `ClStatusBadge` / `ClInlineStatusStrip` |
| screen `_ScreenHead` | replace | `ClPageHeader` |
| `dry_run_banner` | rebuild on | `ClBanner` |
| `deckhand_footbar` | rebuild on | `ClInlineStatusStrip` / `ClMetadataKvList` |
| `progress_run_workspace` | rebuild on | `ClPanel` + `ClLogView` + `ClOperationStepRail` |
| `host_approval_gate`, `network_panel`, `resume_gate`, `save_debug_bundle` | rebuild (Deckhand logic) on forge primitives |
| `deckhand_app_chrome` | keep (thin frame) | fill `ProductShellFrame` slots with `ClCommandBar` + `ClThemeToggle` |
| `deckhand_logo`, `wizard_nav_map`, `profile_text` | **keep** | — |

> Agents MUST read the target forge component's source from the sibling Forge
> checkout, the package cache, or the pinned commit before swapping. The public
> surface is `package:forge/forge.dart` only.

## Wizard engine (`deckhand_core`)

`deckhand_core.WizardState` ≈ `forge_wizard.ForgeWizardState`;
`WizardController` ≈ a thin owner over `ForgeWizardFlowProcess`.

- `WizardState` becomes a `ForgeWizardState` subtype (`subjectId`=profileId,
  `flowId`=flow, `decisions`, `currentStepId`, `connection`=ssh host/port/user).
- `WizardController` wraps `ForgeWizardFlowProcess<WizardState>`; persistence
  uses `ForgeWizardStateCodec`. Deckhand-specific behavior (`loadProfile`,
  `connectSsh`, `printerState`, `events`, secrets-never-serialized) is kept.
- `forge_wizard` is pure-Dart → no Flutter leaks into `deckhand_core`.

## Phases, tasks, validation

Each phase ends green before the next begins. Validation commands run from
`deckhand-app/`. Flutter: `D:\git\flutter\bin\flutter.bat`.

### Phase 0 — Foundation / wiring  *(sequential; owner: lead)*
- [x] Work directly on `main` in `deckhand-app`.
- [x] Add forge / forge_wizard pinned git deps (table above); drop IBM Plex fonts.
- [x] Remove `.gitmodules` and all nested first-party gitlinks.
- **Test plan:** `flutter pub get` resolves in `app/`, `packages/deckhand_ui/`,
  `packages/deckhand_core/`.
- **Validation:** `flutter pub get` exit 0; `forge` + `forge_wizard` appear in
  each `pubspec.lock`.

### Phase 1 — Theme foundation  *(sequential; owner: lead)*
- [x] `wizard_shell.dart`: `MaterialApp.router` theme/darkTheme →
      `buildClTheme(brightness, density: ClDensity.compact, accentPalette: ClAccentPalette.violet)`.
- [x] Delete `theming/deckhand_theme.dart`, `theming/deckhand_tokens.dart`
      (and the `oklch()` helper), and the `deckhand_ui.dart` barrel exports for them.
- [x] Update `test/helpers.dart` to pump through `buildClTheme`.
- **Test plan:** package will not compile until Phase 2 finishes (expected).
- **Validation:** `grep -r DeckhandTokens lib/` returns only files queued for
  Phase 2; theme bootstrap references resolve.

### Phase 2 — Token + widget sweep  *(parallel fan-out; owner: team)*
Decomposed by file group; each group applies the token map + widget map.
- [x] Group A — screens 1–10
- [x] Group B — screens 11–20
- [x] Group C — screens 21–29
- [x] Group D — widgets: delete-and-replace set
- [x] Group E — widgets: rebuild-on-forge set
- **Test plan:** per-group self-check that no `DeckhandTokens`/deleted-widget
  refs remain in the group's files.
- **Validation:** after all groups, `grep -r "DeckhandTokens\|DeckhandTheme" lib/`
  is empty; deleted widget files removed.

### Phase 3 — Chrome + stepper  *(sequential; owner: lead)*
- [x] `deckhand_app_chrome`: `_TopBar` → `ClCommandBar` + `ClNavPill`;
      `ThemeToggleButton` → `ClThemeToggle`.
- [x] `deckhand_stepper` adapter → feeds `ClWizardPhaseStepper`.
- [x] All 29 screens → `ClWizardPageScaffold` + `ClPageHeader`.
- **Validation:** `flutter analyze packages/deckhand_ui` — drive to 0 errors.

### Phase 4 — Wizard engine  *(sequential; owner: dedicated agent)*
- [x] `deckhand_core`: `WizardState`→`ForgeWizardState`, `WizardController`
      wraps `ForgeWizardFlowProcess`, persistence via `ForgeWizardStateCodec`.
- **Test plan:** existing `deckhand_core` wizard tests must pass unchanged in
  behavior (decisions graph, resume, secrets-not-serialized).
- **Validation:** `flutter test packages/deckhand_core` green.

### Phase 5 — Convergence  *(sequential loop; owner: lead)*
- [x] `flutter analyze` (workspace) → fix → repeat until 0 errors.
- [x] `flutter test packages/deckhand_ui packages/deckhand_core` → fix → green.
- [x] Remove IBM Plex font assets from disk.
- **Validation:** analyze 0 errors; all non-golden tests pass.

### Phase 6 — Manual QA  *(owner: lead)*
- [x] Manual smoke: both wizard flows (stock-keep, fresh-flash), light + dark.
- **Note:** `deckhand_ui` has NO golden tests (no `matchesGoldenFile` / `goldens/`),
  so nothing needs regenerating — the earlier "goldens on Linux" plan was moot.
- **Validation:** smoke checklist signed off.

## Acceptance criteria
- No `package:deckhand_ui` references to `DeckhandTokens`/`DeckhandTheme`.
- Deleted widgets (table) removed from the tree.
- `deckhand_ui` + `app` depend on `forge`; `deckhand_core` on `forge_wizard`;
  all first-party external packages are pinned git dependencies.
- IBM Plex assets gone; app renders in Geist with forge violet.
- `flutter analyze` clean; unit/widget tests green; goldens regenerated on Linux.

## Risks & rollback
- **All-red window:** between Phase 1 (delete tokens) and end of Phase 2 the
  package does not compile. This is expected for a no-compat replacement;
  converge in Phase 5.
- **Goldens are Linux-only** — never commit goldens rendered on Windows
  (font-hinting drift); defer to CI.
- **Rollback:** revert the `main` commit that changed the manifests and
  generated locks; do not reintroduce submodules.
