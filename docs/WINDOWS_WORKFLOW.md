# Windows workflow

You can develop this app from Windows, but iOS compilation and signing still need a macOS/Xcode environment. The practical setup is:

1. Edit code on Windows with VS Code, Codex, or another editor.
2. Push the repository to GitHub, GitLab, or Bitbucket.
3. Connect the repository to Codemagic.
4. Let Codemagic build the signed `.ipa` on a hosted Mac.
5. Install through TestFlight on the physical iPhone and test Garmin notification mirroring.

## Required accounts and devices

- Windows 11 for daily development.
- iPhone 14 with iOS 26.5.2 or later.
- Garmin Forerunner 965 paired through Garmin Connect.
- Apple Developer Program membership for signing and TestFlight distribution.
- Codemagic account connected to the source repository.

## Codemagic setup

The root `codemagic.yaml` contains a native iOS workflow.

Before the first build:

1. In Apple Developer/App Store Connect, create the app record and confirm the bundle identifier.
2. In Codemagic, connect App Store Connect under Team integrations.
3. If your integration is not named `codemagic`, update `integrations.app_store_connect` in `codemagic.yaml`.
4. If you change the bundle identifier in Xcode, also update `environment.ios_signing.bundle_identifier`.
5. Start the `SnoreAlert iOS Native` workflow.

## First-device test checklist

1. Install the build on the iPhone through TestFlight.
2. Allow microphone access.
3. Allow notifications.
4. In iOS notification settings, make sure SnoreAlert notifications are allowed and available in Notification Center.
5. In Garmin Connect/Forerunner settings, enable notification vibration and disable notification sound.
6. Open SnoreAlert, tap Start, then tap Test vibration.
7. Lock the screen and test with real snoring or a controlled playback sample.

## Important limitation

Windows cannot run Xcode, iOS Simulator, or on-device iOS debugging directly. For this specific app, simulator testing is not enough anyway because locked-screen microphone behavior and Garmin notification mirroring must be validated on a real iPhone.

