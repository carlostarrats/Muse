# Releasing Muse (direct distribution + Sparkle)

Muse ships **outside the Mac App Store**: a Developer ID–signed, notarized
build that updates itself via [Sparkle](https://sparkle-project.org). This
document is the end-to-end checklist for cutting a release that existing
users will receive automatically.

> **Why not the App Store?** Sparkle self-update is incompatible with Mac
> App Store distribution (App Store apps update through the store and may not
> bundle an updater). Muse chose direct distribution so updates can be
> shipped without an App Store submission. If you ever want an App Store
> build too, it must be a *separate* target/configuration with Sparkle
> compiled out.

## One-time setup

1. **Developer ID Application certificate.** In Xcode ▸ Settings ▸ Accounts,
   make sure you have a *Developer ID Application* certificate (not just the
   *Apple Development* one used for local debug builds). This is what signs
   a notarizable, directly-distributed app.

2. **EdDSA signing key.** Already created — the public key is baked into
   `Muse/Info.plist` as `SUPublicEDKey`
   (`QZNDbCzR71yEGGdAzXVbSS5qcOQxhi86Q6aNd+Av9+I=`). The matching **private
   key lives in your login Keychain** (account `ed25519`, shared with other
   Sparkle apps you build). Never commit the private key. To re-print the
   public key or migrate the key to a new machine, use Sparkle's
   `generate_keys` / `generate_keys -x` tools.

3. **Notarization credentials.** Store an app-specific password for
   `notarytool` once:
   ```sh
   xcrun notarytool store-credentials "muse-notary" \
     --apple-id "carlostarrats@icloud.com" \
     --team-id "TV4QZT7A7X"
   ```

4. **Locate the Sparkle tools.** They ship inside the resolved SPM artifact:
   ```sh
   SPARKLE_BIN="$(find ~/Library/Developer/Xcode/DerivedData/Muse-*/SourcePackages/artifacts/sparkle/Sparkle/bin -maxdepth 1 -type d | head -1)"
   # contains: generate_keys, sign_update, generate_appcast
   ```

5. **`create-dmg`** (for the installer DMG with the drag-to-Applications
   background): `brew install create-dmg`.

## The easy way: one command

Once the one-time setup above is done, every release is just:

```sh
scripts/release.sh 1.0.1            # build + notarize + DMG + sign + appcast
scripts/release.sh 1.0.1 --publish  # …and publish the GitHub release too
```

It archives, notarizes and staples the app, builds the DMG with the
drag-to-Applications background, notarizes and staples the DMG, EdDSA-signs
the update, and writes the appcast. Without `--publish` it stops there and
prints the exact `gh release create` command to run when you're ready. The
build number (`CFBundleVersion`) is set automatically from the git commit
count, so it always increases.

The manual breakdown below documents what that script does, step by step,
in case you need to run or debug a single stage.

## Per-release steps (manual)

### 1. Bump the version

In the **Muse** target build settings (or `project.pbxproj`):

- `MARKETING_VERSION` — the human version, e.g. `1.0.1` (Sparkle shows this).
- `CURRENT_PROJECT_VERSION` — the build number; **must increase every
  release** (Sparkle compares this `CFBundleVersion` to decide "newer").

### 2. Archive + export a Developer ID build

```sh
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse \
  -configuration Release -archivePath build/Muse.xcarchive archive

xcodebuild -exportArchive -archivePath build/Muse.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export
```

`ExportOptions.plist` should specify `"method": "developer-id"`. (You can also
do Product ▸ Archive ▸ Distribute App ▸ *Direct Distribution* in the Xcode
UI, which performs the export and notarization in one flow.)

### 3. Build the DMG, then notarize + staple

Build the installer DMG with the drag-to-Applications background (the script
stages the app, lays out the Muse.app + Applications icons over
`dmg/dmg-background.jpg`, and writes the `.dmg`):

```sh
scripts/make-dmg.sh build/export/Muse.app build/releases/Muse.dmg
```

Notarize the **DMG** (it contains the already-Developer-ID-signed app), then
staple the ticket onto the DMG so it validates offline:

```sh
xcrun notarytool submit build/releases/Muse.dmg --keychain-profile "muse-notary" --wait
xcrun stapler staple build/releases/Muse.dmg
```

> Sparkle updates straight from the DMG — it mounts the volume and copies
> `Muse.app` out — so the DMG is both the first-install download *and* the
> auto-update payload. No separate zip is needed.

### 4. Sign the update + generate the appcast

Put the stapled `Muse.dmg` in an otherwise-empty folder (here
`build/releases/`) and run `generate_appcast`. It signs each archive with your
Keychain EdDSA key and writes `appcast.xml`, pointing enclosure URLs at the
GitHub release you're about to create (replace `<TAG>`, e.g. `v1.0.1`):

```sh
"$SPARKLE_BIN/generate_appcast" build/releases/ \
  --download-url-prefix "https://github.com/carlostarrats/Muse/releases/download/<TAG>/"
```

This produces `build/releases/appcast.xml`. (Add release notes by dropping a
`Muse.html` next to the DMG, or edit the generated `<description>`.)

### 5. Publish the GitHub Release

Create a release whose **tag matches `<TAG>`** and upload **both** assets:

```sh
gh release create <TAG> \
  build/releases/Muse.dmg \
  build/releases/appcast.xml \
  --title "Muse <MARKETING_VERSION>" --notes "…"
```

That's it. Because `SUFeedURL` is
`https://github.com/carlostarrats/Muse/releases/latest/download/appcast.xml`,
every running copy of Muse fetches the appcast from the **latest** release,
sees the new `sparkle:version`, verifies the EdDSA signature against the
embedded public key, and offers the update.

## Verifying

- **Self-test the feed:** `curl -L https://github.com/carlostarrats/Muse/releases/latest/download/appcast.xml`
  should return the XML you uploaded.
- **Self-test the updater:** install an *older* build, then **Muse ▸ Check for
  Updates…** — you should get the update sheet. ⚠️ The sandboxed install path
  runs through Sparkle's bundled `Installer.xpc` / `Downloader.xpc`; this can
  only be exercised on a **signed + notarized** build, not a local debug run,
  so always smoke-test the real artifact before announcing a release.

## Notes / gotchas

- **`CURRENT_PROJECT_VERSION` must strictly increase.** If two releases share
  a build number, clients won't see the newer one.
- **Keep the private key safe.** Losing it means you can't sign updates that
  existing installs will accept (the public key is compiled into shipped
  apps). Back up the Keychain item.
- **`latest/download/…` requires a non-prerelease "latest" release.** If you
  publish a release marked *pre-release*, GitHub won't treat it as "latest"
  and the feed URL will 404 for users.
- **iCloud + App Groups need provisioning profiles even for Developer ID.**
  Unlike a plain Developer ID app, Muse uses iCloud Documents + App Groups, so
  the app *and* the share extension each need a Developer ID provisioning
  profile. The archive/export steps pass `-allowProvisioningUpdates` so Xcode
  creates/refreshes them automatically against your account. If export ever
  fails with `No profiles for 'com.tarrats.Muse…' were found`, that flag (or a
  one-time Distribute App ▸ Direct Distribution in the Xcode UI) is the fix.
- **Notarization requires Hardened Runtime.** Muse was originally
  MAS-configured (no hardened runtime), and notarization rejected it as
  *Invalid*. `release.sh` archives with `ENABLE_HARDENED_RUNTIME=YES`; the
  notarize step also fails loudly on a non-`Accepted` result (notarytool exits
  0 even on *Invalid*) and prints the log.
- **Sandboxed self-update needs the InstallerLauncher XPC + mach-lookup.** A
  sandboxed app can't launch Sparkle's installer directly, so an update will
  download and verify but fail at *"An error occurred while launching the
  installer."* This is configured (don't remove): `Info.plist`
  `SUEnableInstallerLauncherService = true` plus the entitlements
  `com.apple.security.temporary-exception.mach-lookup.global-name` =
  `com.tarrats.Muse-spks`, `com.tarrats.Muse-spki`. These are allowed for
  notarized direct distribution (not App Store). Note the fix only helps the
  app *doing* the updating — a build shipped without it can't self-update to a
  fixed build; that one must be installed manually.
- **The appcast is single-item per release.** `release.sh` prunes the appcast
  dir to just the current DMG and passes `--maximum-deltas 0`, because GitHub
  hosts each version's assets under its own tag — a multi-version appcast with
  one `--download-url-prefix` (or cross-tag deltas) would 404.
