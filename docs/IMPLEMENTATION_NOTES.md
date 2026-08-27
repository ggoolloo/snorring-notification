# Implementation notes

## Detection path

The current implementation uses a lightweight heuristic detector so the app can run before a custom model exists. It looks at short microphone buffers, checks loudness, estimates how much energy sits in a snoring-like frequency range, penalizes sudden low-frequency transients, and looks for repeated snore-like pulses in a slow breathing rhythm before entering the snoring state.

This is not a medical classifier. It is a practical MVP signal that should be replaced or complemented by a Core ML sound classifier after enough positive and negative samples are collected.

## Notification path

The app sends local iOS notifications with `sound = nil`. Garmin Connect mirrors those iPhone notifications to the Forerunner 965. The watch must have notification vibration enabled and notification sound disabled.

iOS and Garmin can throttle, delay, group, or suppress notifications, especially at very short intervals. The app exposes a repeat interval setting and defaults to 3 seconds. The stop delay defaults to 7 seconds so a slow breathing pause does not immediately stop the alert loop.

## Background behavior

The app declares `audio` background mode and uses an active recording session. The intended nightly flow is:

1. User starts listening before sleep.
2. User locks the iPhone screen.
3. The app keeps processing microphone buffers.
4. While snoring is detected, it repeats silent local notifications.
5. After several seconds without snoring, notifications stop.

Physical-device testing is required. Simulator behavior is not enough for locked-screen audio and Garmin notification mirroring.

## Field tuning

If the app vibrates on bed movement, raise sensitivity slightly or keep the iPhone farther from the mattress. If it misses real snoring, lower sensitivity slightly and make sure the phone microphone is not covered.

After the rhythm update, a single loud movement should not trigger immediately. The detector waits for repeated snore-like pulses in a slow breathing tempo, so the first notification can arrive after the second matching breath-like pulse rather than on the first sound.
