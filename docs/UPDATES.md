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
  toggle today. The shipped `Info.plist` does not set `SUEnableAutomaticChecks`
  either way, so Sparkle applies its own default — which, on the second launch
  of the official binary, is to ask you once whether it may check
  automatically, and then to honour that answer. See
  [Sparkle's user documentation](https://sparkle-project.org/documentation/)
  for that prompt and for how an app can offer an in-app toggle instead.
- **Never check at all**: build snapsift yourself from source
  (`app/scripts/build-app.sh` with no `SNAPSIFT_SU_PUBLIC_ED_KEY` set — the
  default for anyone who just clones the repo). That build gets **neither**
  `SUPublicEDKey` **nor** `SUFeedURL` in its `Info.plist`, and snapsift does
  not start the Sparkle updater when `SUFeedURL` is absent: the menu item
  stays disabled, no "check automatically?" prompt appears, and no request is
  made to `oss.cver.net` or anywhere else. The script prints a warning saying
  exactly that when you run it this way.

  (The two keys travel together deliberately. An earlier build script wrote
  `SUFeedURL` unconditionally, which made this paragraph untrue: Sparkle then
  had a feed and only lacked a key to verify it with, and depending on how it
  judged the ad-hoc signature it either showed a modal "Unable to Check For
  Updates" a second after every launch or asked permission on the second
  launch and then fetched the feed on every launch after that.)

## Maintainer release steps

One command runs the chain (`scripts/release.sh`); each stage is also usable
alone. Two repos are involved: this one and the family's private `cver-tools`
signing pipeline (`mac-release/release.sh`), which is not part of this repo —
point `SNAPSIFT_MAC_RELEASE` at it and the script fails with a clear message if
it is absent.

```bash
export SNAPSIFT_MAC_RELEASE=<path to cver-tools>/mac-release/release.sh
export SNAPSIFT_SU_PUBLIC_ED_KEY=<EdDSA PUBLIC key, see "One-time key setup">
export SNAPSIFT_IDENTITY="Developer ID Application: … (TEAMID)"
scripts/release.sh            # build → preflight → sign+notarize+staple+dmg → appcast
SNAPSIFT_PUBLISH_DIR=<checkout of the host> scripts/release.sh publish
```

1. **Build** (`app/scripts/build-app.sh release`, run by `release.sh` into
   `dist/stage/`, never into `~/Applications`) — with
   `SNAPSIFT_SU_PUBLIC_ED_KEY` set the script writes both `SUPublicEDKey` and
   `SUFeedURL`; without it, neither (updates off). The result has
   `Sparkle.framework` embedded and an **ad-hoc** signature (verified with
   `codesign --verify --deep --strict`); ad-hoc is not distribution signing,
   step 2 replaces it. Bump `CFBundleVersion` in `app/Info.plist` for every
   release: Sparkle compares it, and `release.sh` refuses a number that is not
   greater than the newest already in `appcast.xml`.
2. **Sign, notarize, package** — `mac-release/release.sh`, with
   `app/Resources/snapsift.entitlements` (the photos-library entitlement is
   required under the hardened runtime; without it the Photos prompt never
   appears). It signs inside-out — every nested Sparkle item, then the app —
   notarizes, staples, then builds the `.dmg`. The archive is therefore made
   after stapling; do not rebuild or edit it afterwards.
3. **Appcast** — `scripts/make-appcast.sh dist/releases` (Sparkle's
   `generate_appcast`) writes `appcast.xml` from every archive in that
   directory, signing each entry with the EdDSA private key (see below). Keep
   all past release archives in that directory: the feed is regenerated from
   what is there.
4. **Publish** — see "Hosting" below.

### Hosting

One variable decides where updates live: `SNAPSIFT_BASE_URL` (default
`https://oss.cver.net/snapsift/`, a directory URL with a trailing slash). It
is baked into `SUFeedURL` (`<base>appcast.xml`) and used as the appcast
download prefix (`<base><archive>`), so the host MUST serve both
`appcast.xml` and every release archive under that URL, over HTTPS, before the
first official build is shipped. Verify with `curl -I`: both must answer 200
(a redirect to the real file is fine).

As of 2026-10-13 the default base answers 404: `oss.cver.net` is the
organization's GitHub Pages site, which serves a project repo at
`oss.cver.net/<repo>/` only when Pages is enabled on that repo, and it is not
enabled on `CVERInc/snapsift`. Enabling it (Settings ▸ Pages ▸ branch `main`,
folder `/ (root)`) would also publish `index.html`, the landing page. If the
archives should not live in git (they grow the repo and Pages has a size
limit), host them elsewhere and set `SNAPSIFT_BASE_URL` /
`SNAPSIFT_DOWNLOAD_URL_PREFIX` accordingly. Any base URL works as long as it
is used consistently for the build and the appcast.

`scripts/release.sh publish` copies `appcast.xml`, the `.dmg` and its
`.sha256` into `SNAPSIFT_PUBLISH_DIR` (a local checkout of whatever serves the
base URL) and prints the verification commands. It never commits or pushes;
that, and the Pages setting, are the maintainer's.

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
