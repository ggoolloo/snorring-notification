# Implementation notes

## Detection path

The app now uses a local detector with explicit episode states. It analyzes copied microphone PCM buffers on a serial analysis queue, estimates loudness relative to a slow adaptive noise floor, computes Hann-windowed band energy in snore-like, sub-bass, and speech-like ranges, and segments separate breath-like pulses.

The detector enters `snoring` only after at least three supported pulses and two recent stable breathing intervals. A single movement, speech burst, or two isolated sounds should not start notifications anymore.

Apple SoundAnalysis is attached to the live stream with the built-in classifier when available. If the OS exposes a snoring label, its confidence can boost the acoustic score. The app logs when the built-in classifier has no snoring label. It does not treat the presence of SoundAnalysis as proof that detection is accurate.

This is not a medical classifier. It is a practical personal alerting signal that still needs real night testing and more labelled negative data.

## Notification path

The app sends local iOS notifications with `sound = nil`. Garmin Connect mirrors those iPhone notifications to the Forerunner 965. The watch must have notification vibration enabled and notification sound disabled.

iOS and Garmin can throttle, delay, group, or suppress notifications, especially at very short intervals. The app exposes a repeat interval setting and defaults to 3 seconds.

The stop delay defaults to 7 seconds. During an episode the effective timeout can grow up to 15 seconds based on the detected breathing period, so a slow pause between snores does not immediately stop the alert loop. The notification timer checks the active session and freshness window before each send, so old delayed work should not restart alerts after Stop or after an episode ends.

## Background behavior

The app declares `audio` background mode and uses an active recording session. The intended nightly flow is:

1. User starts listening before sleep.
2. User locks the iPhone screen.
3. The app keeps processing microphone buffers.
4. While snoring is detected, it repeats silent local notifications.
5. After the effective timeout without a confirmed snore pulse, notifications stop.

Physical-device testing is required. Simulator behavior is not enough for locked-screen audio and Garmin notification mirroring.

## Local replay

The script `scripts/snore_replay.py` is a Windows-friendly diagnostic replay. It decodes local M4A samples with PyAV and NumPy if they are installed in `%TEMP%\snore-review-deps`, and it runs an approximation of the same pulse and rhythm rules without sending notifications.

Results from 2026-09-12 at default sensitivity 0.72:

- `samples/snoring_positive/snorring.m4a`: 523.499 s, 4 predicted snoring episodes.
- `samples/non_snoring_negative/no-snorring.m4a`: 272.981 s, 0 predicted snoring episodes.

The old stored default threshold 0.72 migrates to sensitivity 0.65. At that migrated value the same replay found 3 predicted episodes in the positive sample and 0 predicted episodes in the negative sample.

This replay is not a full iOS SoundAnalysis test and it does not prove Garmin vibration delivery. It is useful for regression checks against the supplied local samples.

## Field tuning

Higher sensitivity now means more sensitive detection. If the app vibrates on bed movement, lower sensitivity slightly or keep the iPhone farther from the mattress. If it misses real snoring, raise sensitivity slightly and make sure the phone microphone is not covered.

The detector waits for repeated snore-like pulses in a slow breathing tempo, so the first notification can arrive after the third matching breath-like pulse rather than on the first sound. This delay is intentional to avoid alarms from speech and bed movement.

## Tests still needed

- Build through the existing GitHub Actions workflow and install the IPA through the current Windows/Sideloadly flow.
- On iPhone 14, test at least 30 minutes with the screen locked, then one full night.
- Verify that SoundAnalysis on the installed iOS exposes a snoring label in the app logs.
- Verify repeated silent iOS notifications separately from actual Garmin vibration.
- On Garmin Forerunner 965, test with Sleep Mode active, DND off, vibration on, and notification sound off.
- Add hand-labelled time ranges for snoring, speech, movement, breathing, silence, and uncertain sections before claiming precision or recall.
