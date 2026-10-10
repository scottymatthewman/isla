# Security policy

## Supported versions

The `main` branch is the supported version. Isla is a local macOS app and has no hosted service to patch.

## Reporting a vulnerability

Report security issues in private:

1. Open a draft advisory at <https://github.com/scottymatthewman/isla/security/advisories/new>.
2. Include the macOS version, the Isla commit, and steps to reproduce.
3. Use placeholder values. Leave real keys and tokens out of the report.

A public GitHub issue is the wrong channel for a vulnerability.

## What the app does

- Secret values and notes are stored in the login Keychain. `metadata.json` keeps names and Keychain account ids.
- The UI masks values. A reveal lasts about 20 seconds.
- Copying a value schedules a clipboard clear 60 seconds later, and the clear runs only if that same value is still on the clipboard.
- App lock uses Touch ID or the Mac account password on launch, then again after idle time while Isla is active. Both behaviors are configurable in Settings.
- The app target enables the App Sandbox and the Hardened Runtime.

## Assumptions

Isla reduces accidental exposure of keys on a Mac you trust. FileVault and the Keychain are the at-rest controls. A person or program that can already act as you in an unlocked session can read the same secrets Isla can read.
