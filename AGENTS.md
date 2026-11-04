# Duo Display application repository

Preserve the existing bundle identifiers, Debug/Release separation, entitlements, signing requirements and wire/discovery identifiers. Legacy protocol identifiers are not user-facing branding. Do not change connection, codec or display behavior during UI work.

Mac releases require an explicit request and a frozen SHA-256-verified source candidate. Use scripts/release/mac.py and MAC_RELEASE.md. Keep Apple credentials and the Sparkle private key in the local Keychain. Prepare drafts first; never publish a draft without explicit approval of the exact version/build. Do not add push, save, watcher or CI publishing triggers.

iOS uploads require separate explicit approval for the exact app version/build. Do not submit App Review, beta review or tester invitations without authorization.

The website is managed separately. Never deploy a website, configure Pages/Netlify, change DNS, or link automatic builds from this repository.
