# Duo Display Mac releases

The sender and receiver use separate signed Sparkle feeds hosted as GitHub Release
assets in `matthewjgl/duo-display`. The release pipeline is independent of the
Netlify website. It never publishes a website, changes DNS, uploads an iOS build,
or distributes a build when a commit is pushed.

## Local signing

- Apple team: `23222L722A`.
- Release identities: `com.matthewjgl.duodisplay.mac` and
  `com.matthewjgl.duodisplay.mac.receiver`.
- Developer ID Application signing identity is in the local Keychain.
- Sparkle private key account: `com.matthewjgl.duodisplay.sparkle` in Keychain.
  The public key is in `project.yml`. Never rotate the update key without a
  planned signed transition. Back it up securely outside the repository.
- Notarization credential profile: `DuoDisplay` in Keychain. If missing, the
  owner runs `xcrun notarytool store-credentials DuoDisplay --apple-id YOUR_APPLE_ID --team-id 23222L722A`
  and enters an Apple app-specific password at the hidden prompt. Never put
  passwords, private keys, certificates, or `.env` in a commit or chat.
- No credentials are uploaded to GitHub. Signing and notarization run locally;
  GitHub Actions only provides a manually requested unsigned build check.

## Prepare an explicit release

Choose a new `x.y.z` version and an increasing Apple-valid build number.

```sh
python3 scripts/release/mac.py prepare --version 1.0.0 --build 1
```

The command copies only app sources into `build/releases/VERSION-BUILD/source`,
records SHA-256 hashes, generates the Xcode project in that copy, archives both
architectures, verifies Developer ID signatures, notarizes and staples each app
and DMG, and generates and verifies signed appcasts. It publishes nothing.
It never rebuilds or re-signs the active development apps.

With notarization credentials pending, use `--build-only`. Resume without
rebuilding or creating duplicate Apple requests:

```sh
python3 scripts/release/mac.py notarize --artifact build/releases/1.0.0-1
```

Every Apple submission ID is recorded. If a request is pending or rejected,
inspect it with `xcrun notarytool info` / `log`; do not blindly resubmit.
The frozen candidate is never overwritten by `prepare`.

## Draft, review, then publish

After pushing the exact app sources to the Duo Display repository, write release
notes that distinguish hardware-tested behavior from unverified behavior.

```sh
python3 scripts/release/mac.py draft --artifact build/releases/1.0.0-1 --commit EXACT_COMMIT_SHA --notes /path/to/release-notes.md
```

This creates a draft with two DMGs, two signed feeds, a release manifest, and the
corresponding GPL source. It refuses to overwrite an existing release. Review
the version, signing team, hashes, warnings and testing before approving release.
Only after the user explicitly approves this exact release:

```sh
python3 scripts/release/mac.py publish --tag v1.0.0
```

Publishing makes downloads and feeds public. End users can then use Check for
Updates; automatic checks are enabled, automatic installation/download is off.
Debug builds never start Sparkle or update themselves to a Release app.

Feeds:
- `https://github.com/matthewjgl/duo-display/releases/latest/download/appcast.xml`
- `https://github.com/matthewjgl/duo-display/releases/latest/download/appcast-receiver.xml`

Keep sender and receiver feeds together on each stable release. A newer unrelated
stable GitHub Release without these assets would break the `latest` feed URLs.
Never mark a release latest until all assets are verified. The updater cannot
update older OpenDisplay installations with different bundle IDs; those need an
initial manual Duo Display installation.

## Current verification

On 2026-11-04 both apps archived successfully as universal arm64/x86_64 version
1.0.0 build 1, signed by the Developer ID identity for team 23222L722A. Frozen
source snapshot: `ae4a8a386818c286adce10713d0afd24be80f793ae4dfd0639197982d30286df`.
The public source repository is now https://github.com/matthewjgl/duo-display.
Its source was verified against both frozen archives. The signed appcast and
archive smoke test passes, and a tampered archive is rejected. Apple notarization
is waiting for the owner to save the `DuoDisplay` Keychain credential profile.
Public feed/download verification waits until an approved release is published.
No public Mac release has been made. Live USB/Wi-Fi streaming was not re-tested
as part of release setup.

The isolated publishing checkout is `build/github-duo-source` (with its own Git
history and `origin`). The main development checkout retains its existing Git
history and upstream remote. Copy only reviewed application/build source into the
publishing checkout before an explicit source push; never copy websites, local
notes, credentials or build output. The draft command verifies that every frozen
application source file matches the exact public commit before uploading assets.
