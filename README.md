# SnoreAlert

SnoreAlert is an iPhone app prototype for detecting snoring while the screen is locked and sending repeated vibration-only notifications to a Garmin Forerunner 965 through normal iOS notification mirroring.

## Current scope

- SwiftUI iOS app scaffold.
- Background microphone mode via `UIBackgroundModes = audio`.
- Local on-device snoring detector that combines acoustic features, separate breath-like pulses, breathing rhythm, and optional Apple SoundAnalysis support.
- Repeated silent local notifications while snoring continues.
- Settings for sensitivity, repeat interval, and stop delay.
- Sample folders for future personalization/training.

The Xcode project is in `SnoreAlert/SnoreAlert.xcodeproj`.

For Windows-only development, see `docs/WINDOWS_WORKFLOW.md`. For the free personal-device path without App Store/TestFlight, see `docs/FREE_WINDOWS_INSTALL.md`. The repository also includes a `codemagic.yaml` workflow for building a signed iOS `.ipa` on a hosted Mac.

## Samples

Upload audio samples into:

- `samples/snoring_positive/` for recordings that contain snoring.
- `samples/non_snoring_negative/` for silence, normal breathing, speech, coughing, bedding noise, fan/AC, traffic, and other non-snoring sounds.

Please use only recordings where everyone recorded has consented. The first useful batch can be small: 10-20 minutes of snoring and 30+ minutes of non-snoring is enough to start testing a personalized classifier.

Supported formats for local diagnostics or future training: WAV, M4A, MP3, CAF.

The helper script `scripts/snore_replay.py` can replay local M4A samples on Windows when PyAV and NumPy are available in `%TEMP%\snore-review-deps`. It does not send notifications and does not upload recordings.

## Garmin setup

On the iPhone, allow SnoreAlert notifications. In Garmin Connect and on the Forerunner 965, keep phone notifications enabled, sound/tone disabled, and vibration enabled. The app sends silent iOS notifications; the vibration comes from Garmin's mirrored notification behavior.

## Build notes

This workspace was created on Windows, so Xcode build verification was not run here. Open the project on macOS with an iOS 26.5+ SDK, set your development team, then run on a physical iPhone because the simulator does not provide realistic locked-screen microphone behavior.
