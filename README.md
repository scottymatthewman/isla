# Isla

Local key manager for macOS. Isla stores API keys and other secrets on your Mac, grouped by workspace, with values kept in the Keychain and an app lock in front of the window.

## Features

- Workspaces you can create, rename, reorder, and delete
- Secrets with a key, masked value, environments, provider, and notes
- Search, environment filters, and sort by key or last update
- One-click copy of a key or value
- Clipboard clear 60 seconds after copying a value, when that value is still on the clipboard
- Temporary reveal of a masked value (about 20 seconds)
- Inline edits, plus a bulk environment change for the current selection
- `.env` import from pasted text or a file, with a preview and skip, overwrite, or rename when a key already exists
- Touch ID or Mac password on launch, and an idle lock (default 60 minutes) you can change in Settings

Isla stays on the machine. There is no account, sync, or telemetry.

## Requirements

- macOS 26.2 or later
- Xcode 26 or later

## Build and run

```bash
git clone https://github.com/scottymatthewman/isla.git
cd isla
open isla.xcodeproj
```

Select the **isla** target, open **Signing & Capabilities**, and choose your Team. Then run the **isla** scheme.

Signing is automatic, and the project does not pin an Apple Developer team. Each person building Isla uses their own Apple ID.

## Where data lives

| Data | Location |
| --- | --- |
| Workspace names, key names, environments, providers, timestamps | `~/Library/Application Support/isla/metadata.json` |
| Secret values and notes | macOS login Keychain, service `com.isla.secret-values` |

`metadata.json` stores Keychain account ids. It does not store secret values or notes.

## Security

Isla is for a Mac you control:

- Values and notes are Keychain items with `kSecAttrAccessibleWhenUnlocked`
- The window locks with LocalAuthentication. Launch lock is on by default
- Idle lock runs only while Isla is the active app. Sleep and time spent in other apps do not count down the timer
- The app target uses the App Sandbox and the Hardened Runtime
- Save failures are not logged with secret-bearing payloads

FileVault and the Keychain are the at-rest controls. Someone who can already use your unlocked session can read what Isla can read. Details and how to report a problem are in [SECURITY.md](SECURITY.md).

## Tests

```bash
xcodebuild test -scheme isla -destination 'platform=macOS'
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Design notes from the first version are in [docs/V1_PRODUCT_SPEC.md](docs/V1_PRODUCT_SPEC.md). Where that document and the app disagree, the code is the source of truth.

## License

[MIT](LICENSE) © 2026 Scotty Matthewman
