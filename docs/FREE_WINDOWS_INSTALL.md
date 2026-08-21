# Free Windows install path

This path avoids a paid Apple Developer Program membership and avoids App Store/TestFlight distribution.

The tradeoff is that a free Apple developer account installs apps for 7 days. After that, install or refresh the app again.

## What you need

- Windows 11.
- iPhone 14 with iOS 26.5.2 or later.
- Free Apple Account.
- GitHub account.
- Sideloadly on Windows.
- Web versions of iTunes and iCloud from Apple, not the Microsoft Store versions.

## Flow

1. Push this repository to GitHub.
2. Run the GitHub Actions workflow named `Build unsigned iOS IPA`.
3. Download the `SnoreAlert-unsigned-ipa` artifact.
4. Use Sideloadly on Windows to sign and install the IPA onto your iPhone.
5. Reinstall or refresh within 7 days.

## Why this works

GitHub Actions provides a macOS runner that can compile the iOS app. Sideloadly then signs the compiled IPA with your Apple Account on Windows and installs it to your own phone.

