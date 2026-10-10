# Contributing

Issues and pull requests are welcome.

## Setup

1. Clone the repository and open `isla.xcodeproj` in Xcode.
2. Select the **isla** target and set **Signing & Capabilities → Team** to your Apple ID team.
3. Run the **isla** scheme.

## Pull requests

- Keep each change focused.
- Match the Swift style in the file you are editing.
- Leave secret values, tokens, and `.env` contents out of logs, screenshots, and commits.
- Leave `xcuserdata`, DerivedData, and real environment files out of the diff.
- Say how you checked the change: an Xcode run, `xcodebuild test`, or a manual pass through the screen you touched.

## Security reports

Use a private [GitHub Security Advisory](https://github.com/scottymatthewman/isla/security/advisories/new). See [SECURITY.md](SECURITY.md).
