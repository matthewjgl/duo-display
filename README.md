# Duo Display

Use an iPhone, iPad, or another Mac as an extra display for your Mac, over USB or your local Wi-Fi network.

This is the Duo Display application source and Mac release repository. The production website is deployed separately from explicitly approved snapshots.

Duo Display is derived from [OpenDisplay](https://github.com/peetzweg/opendisplay), under GPL-3.0. Original copyright and license notices are preserved.

## Build

Requires Xcode, XcodeGen, and the supported SDKs. Run `xcodegen generate`, then build the `OpenSidecarMac` or `OpenSidecarMacReceiver` scheme. Internal scheme and protocol names remain stable for compatibility.

## Releases

See [MAC_RELEASE.md](MAC_RELEASE.md). Signing keys remain in the developer’s local Keychain. Git pushes cannot publish apps, upload iOS builds, or deploy websites. The GitHub Actions readiness check is manual.

Mac release distribution is being prepared. There is no public production Mac release yet.
