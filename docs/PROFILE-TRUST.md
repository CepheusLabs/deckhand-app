# Profile trust model

> The profile-fetch handler in
> [`profiles/fetcher.go`](../sidecar/internal/profiles/fetcher.go)
> already verifies signed tags against a passed-in PGP keyring.
> This document covers where that keyring comes from in
> production, how it's rotated, and what the user sees when
> trust decisions are made.

## Threat model

deckhand-profiles is a public GitHub repository. Profiles drive
*everything* Deckhand does on the printer — package installs,
service replacement, MCU flashes — so a compromised profile is
indistinguishable from a compromised installer. The trust
question is "did a Deckhand maintainer actually publish this
profile tag, or did someone else push a tag with the same name?"

Within scope:

- A GitHub account compromise letting an attacker push tags.
- A maintainer's local machine compromise letting an attacker
  steal the GitHub PAT but not the offline signing key.
- A typo'd tag name in the registry resolving to an attacker's
  fork.

Out of scope:

- An attacker who has the maintainer's offline signing key.
  The mitigation here is operational (key custody, rotation
  cadence, `RELEASING.md`).
- Compromise of the upstream Klipper / Kalico / Mainsail / Fluidd
  source. Deckhand records the resolved commit SHA of every
  upstream fetch in the run-state file
  ([STEP-IDEMPOTENCY.md](STEP-IDEMPOTENCY.md)) so a post-hoc audit
  can identify what was pulled, but profiles already pin upstream
  refs to specific tags — that's the upstream pinning story, not
  this one.

## Trust roots

Deckhand ships with a **bundled trust bundle** at
`app/assets/keyring.asc`. Contents:

- The current Cepheus Labs profile-signing key (offline; only
  used to sign deckhand-profiles release tags).
- The previous key, kept active for one release after rotation
  so a user on an older Deckhand release can still verify a new
  tag during the rollover window.

The keyring is embedded into the Dart binary at compile time
via `package:flutter` asset bundling, *not* fetched at runtime.
Fetching the keyring at runtime would defeat the purpose: the
keyring is what authenticates the very thing we'd use to
authenticate a remote keyring.

The Go sidecar receives the keyring from the UI on every
`profiles.fetch` call ([IPC.md](IPC.md)) — there is no separate
sidecar keyring file. This keeps the trust state in one place
(the bundled UI binary) and makes the sidecar stateless about
trust.

## Bootstrap flow

First-time install of Deckhand:

1. User downloads Deckhand from https://dh.printdeck.io/. The
   landing page surfaces the SHA-256 from `manifest.json`
   ([RELEASING.md](RELEASING.md)) and the GPG fingerprint of
   `SHA256SUMS.asc`. Users who care can verify out-of-band.
2. The bundled keyring authenticates *future* profile fetches.
   It does not authenticate itself — that responsibility is on
   the Deckhand release artifact, signed via Authenticode on
   Windows and Developer-ID on macOS.
3. On first launch, S15-pick-printer
   ([WIZARD-FLOW.md](WIZARD-FLOW.md)) calls `profiles.fetch` with
   `trusted_keys` populated from the bundled keyring and
   `require_signed_tag = true`. A failed verification surfaces
   the `unsigned_or_untrusted` error (existing IPC contract) and
   the UI shows a hard-stop screen with the signer fingerprint
   we expected.

## Per-fetch UI

Every successful profile fetch surfaces the signer in the UI:

- S15-pick-printer card: small "Verified by Cepheus Labs
  (`F4A2…7C9D`)" caption next to the printer name. Clicking
  expands to the full fingerprint and the tag name.
- Profile-update notification (Settings → Profiles → "Check for
  updates"): if a new tag's signer fingerprint differs from the
  previously-cached one, the update prompt highlights the change
  and requires a one-line user acknowledgement before installing.
  This catches a key rotation that wasn't preceded by a Deckhand
  binary update.

## Rotation

Maintainers rotate the signing key on a planned cadence (target:
every 18 months) or immediately on suspected compromise. The
process:

1. Generate the new key offline. Add it to
   `keyring.asc` *alongside* the current key (don't replace).
2. Tag the next deckhand-profiles release with the new key. Push.
3. Cut a Deckhand release with the updated keyring. The first
   user run after upgrade sees both old and new keys as valid
   trust roots — old cached profiles still verify, new tags from
   the new key verify too. No flag day.
4. After one full deckhand-profiles release on the new key, cut a
   second Deckhand release that drops the old key. Users still
   on the old Deckhand can keep using their cached profiles
   indefinitely; if they update to the new Deckhand they get the
   slimmer keyring with the rotation complete.

Compromise rotation skips step 4's grace period: the next
Deckhand release after the incident drops the old key
immediately, and the release notes explicitly call out that
profiles cached against the old key must be re-fetched.

## Registry pinning

`registry.yaml` in deckhand-profiles lists every published profile
+ its latest signed tag. The registry file itself is fetched
unauthenticated (just a GET against
`raw.githubusercontent.com/CepheusLabs/deckhand-profiles/main/registry.yaml`),
which is fine: the only security property the registry needs is
"point at a tag that we then verify cryptographically." If the
registry is tampered with, the attacker can either:

- Point at an existing signed tag that isn't the one a user
  wanted. Mitigation: tag names are visible in the UI; users
  pinning to a specific version detect this.
- Point at an unsigned or attacker-signed tag. Mitigation:
  `require_signed_tag` rejects it on fetch with the existing
  `unsigned_or_untrusted` error.

## Verification UX when things go wrong

`unsigned_or_untrusted` from `profiles.fetch` lands the user on
a specific error screen (E-profile-untrusted, new — current
[WIZARD-FLOW.md](WIZARD-FLOW.md) error list rolls this into
E-profile-fetch-failed which is too vague):

> ### This profile isn't signed by a trusted Deckhand maintainer.
>
> The deckhand-profiles tag we tried to fetch — `v3.4.1` for
> Sovol Zero — either has no PGP signature, has a signature that
> doesn't match the keys this Deckhand release was built with,
> or is a branch instead of a release tag.
>
> This is unusual and worth taking seriously. If you're a
> profile contributor testing locally, point Deckhand at your
> branch using "Settings → Profiles → Use edge (main branch)
> for…" and acknowledge the warning.
>
> [ Open the troubleshooting guide ] [ Quit ]

Default action is `Quit`. There is no "continue anyway" button
on this screen — silent fallthrough is exactly what the threat
model is designed to prevent. Users who legitimately need to
fetch unsigned content do it through Settings, with a sticky
banner on every wizard screen for the rest of the session.

## Implementation status

- Sidecar verification: implemented in
  [`fetcher.go:126`](../sidecar/internal/profiles/fetcher.go:126).
- `profiles.fetch` IPC contract: documented in
  [IPC.md:148](IPC.md:148).
- Bundled keyring asset: **placeholder present** at
  [`app/assets/keyring.asc`](../app/assets/keyring.asc).
  The placeholder's first-line marker is detected at runtime by
  [`TrustKeyring.loadFromString`](../packages/deckhand_core/lib/src/trust/trust_keyring.dart);
  dev builds force `require_signed_tag` off when the placeholder is still
  in place. Release builds fail closed before the wizard starts if packaging
  forgot to replace the placeholder. Production builds must replace this file
  with an armored PGP keyring containing the active and previous Cepheus Labs
  signing keys, at which point `requireSignedTag` flips on automatically in
  [`app/lib/main.dart`](../app/lib/main.dart).
- Production wiring in `main.dart`: implemented — keyring is
  loaded at startup and forwarded into `SidecarProfileService`
  via the `trustKeyring`/`requireSignedTag` constructor params.
  A persistence-error log entry fires when the placeholder is detected in
  dev builds so contributors notice signed-tag verification is off.
- Rotation procedure in [RELEASING.md](RELEASING.md): pending —
  belongs in a new "Profile signing" section.
- E-profile-untrusted screen: pending in
  [`packages/deckhand_ui/lib/src/screens/error_screen.dart`](../packages/deckhand_ui/lib/src/screens/error_screen.dart).
- "Verified by" caption on S15: pending in
  [`pick_printer_screen.dart`](../packages/deckhand_ui/lib/src/screens/pick_printer_screen.dart).
