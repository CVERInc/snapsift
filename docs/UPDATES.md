# Auto-updates

The signed, notarized build of snapsift ("the official binary" — see
`README.md` for how that differs from building the app yourself from this
source) checks for new versions using [Sparkle 2](https://sparkle-project.org),
the same open-source updater framework most independent Mac apps use.

## What it checks, and what it sends

On launch, and whenever you choose **snapsift ▸ Check for Updates…** from the
menu bar, Sparkle fetches `SUFeedURL` (an `appcast.xml` file — plain, static
XML, no server-side logic) and compares its own app version against the
newest entry in it.

The request Sparkle makes for that is an ordinary HTTPS `GET` of the feed
URL. Beyond what any HTTP request carries by default (client IP, User-Agent),
snapsift sends nothing else: `SUEnableSystemProfiling` is explicitly set to
`false` in the shipped `Info.plist`, which turns off Sparkle's optional
hardware/OS profiling payload (normally sent with the user's consent, to help
maintainers see which macOS versions are in use). No usage analytics, no
crash reports, no photo-library data — snapsift never sends anything about
your library anywhere, auto-update included.

If a newer version is listed, Sparkle shows it to you (with its release
notes) and asks before downloading or installing anything. Downloaded
updates are verified against `SUPublicEDKey` (an EdDSA public key baked into
`Info.plist`) before Sparkle will install them, so a compromised or
spoofed feed/download can't push a tampered build.

## Turning it off

- **Skip one version**: click "Skip This Version" in the update dialog.
- **Turn off background checks**: `snapsift ▸ Settings…` has no separate
  toggle today (Sparkle's own default: it still checks, silently, and only
  ever shows you something when there *is* an update — see
  [Sparkle's user documentation](https://sparkle-project.org/documentation/)
  for the `SUEnableAutomaticChecks` default and how a user can be given a
  toggle for it in-app).
- **Never check at all**: build snapsift yourself from source
  (`app/scripts/build-app.sh` with no `SNAPSIFT_SU_PUBLIC_ED_KEY` set — the
  default for anyone who just clones the repo). That build has no public key
  to verify an appcast against, so Sparkle has nothing to trust and never
  offers an update; the script prints a warning saying exactly that when you
  run it this way.

## Maintainer release steps

Producing a shippable update is four steps across two repos — this one and
the family's `cver-tools` signing pipeline:

1. **Build** — `app/scripts/build-app.sh release` with both
   `SNAPSIFT_FEED_URL` (defaults to the production appcast, so usually
   unset) and `SNAPSIFT_SU_PUBLIC_ED_KEY` (the EdDSA **public** key —
   see "One-time key setup" below) set. This produces an unsigned
   `.app` with `Sparkle.framework` embedded and the update-check Info.plist
   keys filled in.
2. **Sign, notarize, package** — `cver-tools`' `mac-release/release.sh`
   (family pipeline; not part of this repo) turns that `.app` into a signed,
   notarized, stapled `.dmg`, using
   `app/Resources/snapsift.entitlements` as its `--entitlements` argument.
   `app/scripts/build-app.sh` prints that entitlements path at the end of
   its own run so it's never typed from memory.
3. **Appcast** — `scripts/make-appcast.sh <dir-of-release-dmgs>` wraps
   Sparkle's own `generate_appcast` to (re)write `appcast.xml` from every
   release archive in that directory, signing each entry with the EdDSA
   private key (see below).
4. **Upload** — publish the new `.dmg` and the regenerated `appcast.xml` to
   wherever `SUFeedURL` points (default: `https://oss.cver.net/snapsift/`).
   Existing installations pick up the update on their next check —
   nothing needs to be pushed to them.

### One-time key setup (human, not scripted)

Sparkle's updates are signed with an EdDSA (ed25519) key pair, generated
once with Sparkle's own `generate_keys` tool (from the same release this repo
pins — see the exact tag in `app/Package.swift`). Run it by hand, on the
machine that will run `scripts/make-appcast.sh`:

- The **private** key goes straight into that Mac's login Keychain
  (`generate_keys` writes it there itself); nothing here ever prints, files,
  or otherwise touches it in plaintext.
- The **public** key is printed once. Save it and use it as
  `SNAPSIFT_SU_PUBLIC_ED_KEY` for every future `build-app.sh` run producing
  the official binary — it's what lets a running copy of snapsift verify that
  an appcast/update `make-appcast.sh` signed is genuine.

Neither `app/scripts/build-app.sh` nor `scripts/make-appcast.sh` ever runs
`generate_keys` themselves; that step is deliberately left to a human,
exactly once.
