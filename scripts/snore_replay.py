from __future__ import annotations

import argparse
import json
import math
import os
import sys
from dataclasses import dataclass
from pathlib import Path


TEMP_DEPS = Path(os.environ.get("TEMP", "")) / "snore-review-deps"
if TEMP_DEPS.exists():
    sys.path.insert(0, str(TEMP_DEPS))

try:
    import av  # type: ignore
    import numpy as np  # type: ignore
except Exception as exc:  # pragma: no cover - environment diagnostic
    raise SystemExit(
        "This replay needs PyAV and NumPy to decode M4A locally. "
        "Install them into %TEMP%\\snore-review-deps or run it on a machine that has them. "
        f"Import error: {exc}"
    )


@dataclass
class Pulse:
    start: float
    end: float
    peak: float


class ReplayDetector:
    def __init__(self, sensitivity: float = 0.72, stop_delay: float = 7.0) -> None:
        self.sensitivity = sensitivity
        self.stop_delay = stop_delay
        self.state = "idle"
        self.noise_floor: float | None = None
        self.previous_db: float | None = None
        self.active_start: float | None = None
        self.active_end: float | None = None
        self.active_peak = 0.0
        self.pulses: list[Pulse] = []
        self.all_pulses: list[Pulse] = []
        self.period: float | None = None
        self.rhythm = 0.0
        self.last_confirmed_end: float | None = None
        self.current_episode_start: float | None = None
        self.episodes: list[tuple[float, float]] = []

    def attack_threshold(self) -> float:
        normalized = min(max((self.sensitivity - 0.45) / (0.92 - 0.45), 0), 1)
        return 0.74 - (0.22 * normalized)

    def update_noise(self, db: float) -> float:
        if self.noise_floor is None:
            self.noise_floor = min(db, -50.0)
            return self.noise_floor
        episode_active = self.state in {"candidate", "snoring"} or self.active_start is not None
        rate = 0.001 if episode_active and db >= self.noise_floor else 0.006
        if db < self.noise_floor:
            rate = 0.12
        updated = self.noise_floor * (1 - rate) + db * rate
        self.noise_floor = min(updated, db - 1)
        return self.noise_floor

    def process(self, samples: np.ndarray, sr: float, start: float) -> None:
        end = start + len(samples) / sr
        rms = float(np.sqrt(np.mean(samples * samples))) if len(samples) else 0.0
        db = 20 * math.log10(max(rms, 1e-6))
        floor = self.update_noise(db)
        jump = abs(db - (self.previous_db if self.previous_db is not None else db))
        self.previous_db = db

        sub = band_energy(samples, sr, 20, 70, 10)
        low = band_energy(samples, sr, 80, 760, 40)
        high = band_energy(samples, sr, 850, 2800, 130)
        total = max(sub + low + high, 1e-6)
        low_ratio = low / total
        speech_ratio = high / total
        sub_ratio = sub / total

        prominence = clamp((db - floor - 4) / 14)
        band_score = clamp((low_ratio - 0.30) / 0.38)
        speech_penalty = clamp((speech_ratio - 0.58) / 0.22)
        sub_penalty = clamp((sub_ratio - 0.45) / 0.25)
        transient = clamp((jump - 10) / 18)
        confidence = clamp(
            0.42 * prominence
            + 0.48 * band_score
            - 0.22 * speech_penalty
            - 0.20 * sub_penalty
            - 0.14 * transient
        )
        threshold = self.attack_threshold()
        supported = confidence >= threshold and prominence >= 0.18 and transient < 0.90 and band_score >= 0.12
        continuing = self.active_start is not None and confidence >= max(0.20, threshold - 0.13) and transient < 0.95

        if supported or continuing:
            if self.active_start is None:
                self.active_start = start
                self.active_peak = confidence
            self.active_end = end
            self.active_peak = max(self.active_peak, confidence)
        else:
            self.finalize_pulse()

        self.pulses = [pulse for pulse in self.pulses if end - pulse.end <= 30]
        if self.state == "snoring" and self.last_confirmed_end is not None:
            timeout = min(max(max(self.stop_delay, 7), 1.8 * (self.period or 0)), 15)
            if end - self.last_confirmed_end > timeout:
                self.episodes.append((self.current_episode_start or end, end))
                self.current_episode_start = None
                self.state = "idle"
                self.pulses.clear()
                self.period = None
                self.rhythm = 0.0

        if self.state != "snoring" and len(self.pulses) >= 3 and self.rhythm >= 0.66 and self.has_stable_recent_intervals():
            recent = self.pulses[-3:]
            if all(pulse.peak >= threshold for pulse in recent):
                self.state = "snoring"
                self.current_episode_start = recent[0].start
                self.last_confirmed_end = recent[-1].end
        elif self.state == "idle" and (self.active_start is not None or self.pulses):
            self.state = "candidate"

    def finalize_pulse(self) -> None:
        if self.active_start is None or self.active_end is None:
            self.clear_active()
            return
        duration = self.active_end - self.active_start
        if 0.24 <= duration <= 2.8 and self.active_peak >= self.attack_threshold():
            pulse = Pulse(self.active_start, self.active_end, self.active_peak)
            self.all_pulses.append(pulse)
            self.add_pulse(pulse)
        self.clear_active()

    def add_pulse(self, pulse: Pulse) -> None:
        if self.pulses and pulse.start - self.pulses[-1].end < 0.75:
            previous = self.pulses[-1]
            self.pulses[-1] = Pulse(previous.start, pulse.end, max(previous.peak, pulse.peak))
            self.recompute_rhythm()
            return
        if self.pulses:
            interval = pulse.start - self.pulses[-1].start
            if not 1.5 <= interval <= 8.5:
                self.pulses = [pulse]
                self.period = None
                self.rhythm = 0.0
            elif self.period and abs(interval - self.period) / max(self.period, 0.1) > 0.48:
                self.pulses = [self.pulses[-1], pulse]
                self.period = interval
                self.rhythm = 0.35
            else:
                self.pulses.append(pulse)
                self.recompute_rhythm()
        else:
            self.pulses.append(pulse)
        if self.state == "snoring":
            self.last_confirmed_end = pulse.end

    def has_stable_recent_intervals(self) -> bool:
        if len(self.pulses) < 3:
            return False
        recent = self.pulses[-3:]
        first = recent[1].start - recent[0].start
        second = recent[2].start - recent[1].start
        if not 1.5 <= first <= 8.5 or not 1.5 <= second <= 8.5:
            return False
        center = max((first + second) / 2, 0.1)
        return abs(first - second) / center <= 0.38

    def recompute_rhythm(self) -> None:
        if len(self.pulses) < 2:
            self.rhythm = 0.0
            self.period = None
            return
        recent = self.pulses[-5:]
        intervals = [recent[i].start - recent[i - 1].start for i in range(1, len(recent))]
        if not intervals or any(interval < 1.5 or interval > 8.5 for interval in intervals):
            self.rhythm = 0.0
            return
        median_interval = float(np.median(intervals))
        deviations = [abs(interval - median_interval) / max(median_interval, 0.1) for interval in intervals]
        median_deviation = float(np.median(deviations))
        count_score = clamp(len(intervals) / 2)
        consistency = clamp(1 - median_deviation / 0.42)
        tempo = 1.0 if 2.0 <= median_interval <= 7.0 else clamp(1 - min(abs(median_interval - 2.0), abs(median_interval - 7.0)) / 1.5)
        self.period = median_interval
        self.rhythm = clamp(0.48 * count_score + 0.38 * consistency + 0.14 * tempo)

    def clear_active(self) -> None:
        self.active_start = None
        self.active_end = None
        self.active_peak = 0.0

    def finish(self, end_time: float) -> None:
        self.finalize_pulse()
        if self.state == "snoring":
            self.episodes.append((self.current_episode_start or end_time, end_time))


def band_energy(samples: np.ndarray, sr: float, start: float, end: float, step: float) -> float:
    if len(samples) == 0:
        return 0.0
    windowed = samples * np.hanning(len(samples))
    freqs = np.arange(start, end + 0.001, step)
    n = np.arange(len(samples))
    powers = []
    for freq in freqs:
        kernel = np.exp(-2j * np.pi * freq * n / sr)
        powers.append(abs(np.dot(windowed, kernel)) ** 2)
    return float(np.mean(powers)) if powers else 0.0


def clamp(value: float) -> float:
    return min(max(value, 0.0), 1.0)


def decode_mono(path: Path) -> tuple[np.ndarray, float]:
    container = av.open(str(path))
    stream = next(s for s in container.streams if s.type == "audio")
    sr = float(stream.rate or 48_000)
    chunks: list[np.ndarray] = []
    for frame in container.decode(stream):
        array = frame.to_ndarray()
        if array.ndim == 2:
            mono = array.astype(np.float32).mean(axis=0)
        else:
            mono = array.astype(np.float32)
        if np.issubdtype(array.dtype, np.integer):
            mono = mono / np.iinfo(array.dtype).max
        chunks.append(mono)
    if not chunks:
        return np.array([], dtype=np.float32), sr
    return np.concatenate(chunks).astype(np.float32), sr


def replay_file(path: Path, sensitivity: float, stop_delay: float, debug_pulses: bool) -> dict[str, object]:
    samples, sr = decode_mono(path)
    detector = ReplayDetector(sensitivity=sensitivity, stop_delay=stop_delay)
    block = 8192
    for index in range(0, len(samples), block):
        detector.process(samples[index : index + block], sr, index / sr)
    detector.finish(len(samples) / sr)
    result: dict[str, object] = {
        "file": str(path),
        "duration_seconds": round(len(samples) / sr, 3),
        "episodes": [(round(start, 2), round(end, 2)) for start, end in detector.episodes],
        "episode_count": len(detector.episodes),
        "final_state": detector.state,
        "final_period_seconds": None if detector.period is None else round(detector.period, 3),
        "final_rhythm_score": round(detector.rhythm, 3),
    }
    if debug_pulses:
        result["pulse_count"] = len(detector.all_pulses)
        result["pulses"] = [
            (round(pulse.start, 2), round(pulse.end, 2), round(pulse.peak, 3))
            for pulse in detector.all_pulses
        ]
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("files", nargs="+", type=Path)
    parser.add_argument("--sensitivity", type=float, default=0.72)
    parser.add_argument("--stop-delay", type=float, default=7.0)
    parser.add_argument("--debug-pulses", action="store_true")
    args = parser.parse_args()

    results = [replay_file(path, args.sensitivity, args.stop_delay, args.debug_pulses) for path in args.files]
    print(json.dumps(results, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
