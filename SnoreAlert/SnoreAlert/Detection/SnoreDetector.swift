import AVFoundation
import Foundation

struct SnoreAnalysis {
    let confidence: Float
    let isSnoring: Bool
    let decibels: Float
    let lowBandRatio: Float
    let rhythmScore: Float
    let transientScore: Float
}

final class SnoreDetector {
    private struct Observation {
        let timestamp: Date
        let confidence: Float
        let isCandidate: Bool
    }

    private var positiveWindows = 0
    private var previousDecibels: Float?
    private var wasCandidate = false
    private var pulseTimes: [Date] = []
    private var observations: [Observation] = []

    func reset() {
        positiveWindows = 0
        previousDecibels = nil
        wasCandidate = false
        pulseTimes = []
        observations = []
    }

    func analyze(buffer: AVAudioPCMBuffer, settings: AppSettings) -> SnoreAnalysis {
        guard
            let channelData = buffer.floatChannelData?[0],
            buffer.frameLength > 0
        else {
            return SnoreAnalysis(
                confidence: 0,
                isSnoring: false,
                decibels: -120,
                lowBandRatio: 0,
                rhythmScore: 0,
                transientScore: 0
            )
        }

        let frameCount = Int(buffer.frameLength)
        let sampleRate = Float(buffer.format.sampleRate)
        let samples = UnsafeBufferPointer(start: channelData, count: frameCount)
        let now = Date()

        let rms = rootMeanSquare(samples)
        let decibels = 20 * log10(max(rms, 0.000_001))

        let subBassBand = bandEnergy(samples: samples, sampleRate: sampleRate, from: 18, to: 65, step: 12)
        let snoreBand = bandEnergy(samples: samples, sampleRate: sampleRate, from: 70, to: 620, step: 35)
        let upperBand = bandEnergy(samples: samples, sampleRate: sampleRate, from: 700, to: 2_400, step: 100)
        let totalBandEnergy = max(subBassBand + snoreBand + upperBand, 0.000_001)
        let lowBandRatio = snoreBand / totalBandEnergy
        let subBassRatio = subBassBand / totalBandEnergy

        let decibelJump = abs(decibels - (previousDecibels ?? decibels))
        previousDecibels = decibels

        let volumeScore = clamp((decibels + 58) / 34)
        let bandScore = clamp((lowBandRatio - 0.34) / 0.34)
        let subBassPenalty = clamp((subBassRatio - 0.42) / 0.25)
        let transientScore = clamp((decibelJump - 9) / 18)
        let confidence = clamp(
            (0.35 * volumeScore) +
            (0.65 * bandScore) -
            (0.35 * subBassPenalty) -
            (0.40 * transientScore)
        )

        let releaseThreshold = max(0.20, settings.sensitivity - 0.16)
        let isCandidate: Bool

        if confidence >= settings.sensitivity {
            isCandidate = true
        } else if wasCandidate && confidence >= releaseThreshold && transientScore < 0.55 {
            isCandidate = true
        } else {
            isCandidate = false
        }

        updatePulseState(isCandidate: isCandidate, timestamp: now)
        updateObservationState(
            Observation(
                timestamp: now,
                confidence: confidence,
                isCandidate: isCandidate
            ),
            currentTime: now
        )

        let rhythmScore = rhythmicBreathingScore(at: now)
        let sustainedCandidateScore = sustainedCandidateScore(at: now)

        if isCandidate && rhythmScore >= 0.45 {
            positiveWindows += 1
        } else {
            positiveWindows = max(0, positiveWindows - 1)
        }

        let hasRhythmicSnoring = rhythmScore >= 0.62 && sustainedCandidateScore >= 0.18
        let hasStrongSnoring = positiveWindows >= settings.requiredPositiveWindows && rhythmScore >= 0.45
        let isSnoring = hasRhythmicSnoring || hasStrongSnoring

        wasCandidate = isCandidate

        return SnoreAnalysis(
            confidence: confidence,
            isSnoring: isSnoring,
            decibels: decibels,
            lowBandRatio: lowBandRatio,
            rhythmScore: rhythmScore,
            transientScore: transientScore
        )
    }

    private func updatePulseState(isCandidate: Bool, timestamp: Date) {
        defer {
            pulseTimes.removeAll { timestamp.timeIntervalSince($0) > 16 }
        }

        guard isCandidate, !wasCandidate else {
            return
        }

        if let lastPulse = pulseTimes.last {
            let interval = timestamp.timeIntervalSince(lastPulse)
            guard interval >= 1.1 else {
                return
            }
        }

        pulseTimes.append(timestamp)
    }

    private func updateObservationState(_ observation: Observation, currentTime: Date) {
        observations.append(observation)
        observations.removeAll { currentTime.timeIntervalSince($0.timestamp) > 12 }
    }

    private func rhythmicBreathingScore(at timestamp: Date) -> Float {
        let recentPulses = pulseTimes.filter { timestamp.timeIntervalSince($0) <= 16 }
        guard recentPulses.count >= 2 else {
            return 0
        }

        var intervals: [TimeInterval] = []
        for index in 1..<recentPulses.count {
            intervals.append(recentPulses[index].timeIntervalSince(recentPulses[index - 1]))
        }
        let breathingIntervals = intervals.filter { $0 >= 1.4 && $0 <= 8.5 }

        guard !breathingIntervals.isEmpty else {
            return 0
        }

        let averageInterval = breathingIntervals.reduce(0, +) / Double(breathingIntervals.count)
        let averageDeviation = breathingIntervals
            .map { abs($0 - averageInterval) }
            .reduce(0, +) / Double(breathingIntervals.count)

        let intervalScore = clamp(Float(breathingIntervals.count) / 3)
        let consistencyScore = clamp(1 - Float(averageDeviation / max(averageInterval, 0.1)))
        let tempoScore = clamp(1 - abs(Float(averageInterval - 3.8)) / 4.7)

        return clamp((0.45 * intervalScore) + (0.35 * consistencyScore) + (0.20 * tempoScore))
    }

    private func sustainedCandidateScore(at timestamp: Date) -> Float {
        let recent = observations.filter { timestamp.timeIntervalSince($0.timestamp) <= 8 }
        guard !recent.isEmpty else {
            return 0
        }

        let candidateCount = recent.filter(\.isCandidate).count
        let averageConfidence = recent.map(\.confidence).reduce(0, +) / Float(recent.count)
        let candidateRatio = Float(candidateCount) / Float(recent.count)

        return clamp((0.65 * candidateRatio) + (0.35 * averageConfidence))
    }

    private func rootMeanSquare(_ samples: UnsafeBufferPointer<Float>) -> Float {
        var sum: Float = 0

        for sample in samples {
            sum += sample * sample
        }

        return sqrt(sum / Float(max(samples.count, 1)))
    }

    private func bandEnergy(
        samples: UnsafeBufferPointer<Float>,
        sampleRate: Float,
        from startFrequency: Float,
        to endFrequency: Float,
        step: Float
    ) -> Float {
        guard startFrequency < endFrequency, step > 0 else {
            return 0
        }

        var energy: Float = 0
        var frequency = startFrequency

        while frequency <= endFrequency {
            energy += goertzelPower(samples: samples, sampleRate: sampleRate, frequency: frequency)
            frequency += step
        }

        return energy
    }

    private func goertzelPower(
        samples: UnsafeBufferPointer<Float>,
        sampleRate: Float,
        frequency: Float
    ) -> Float {
        let normalizedFrequency = frequency / sampleRate
        let coefficient = 2 * cos(2 * Float.pi * normalizedFrequency)
        var q0: Float = 0
        var q1: Float = 0
        var q2: Float = 0

        for sample in samples {
            q0 = coefficient * q1 - q2 + sample
            q2 = q1
            q1 = q0
        }

        return q1 * q1 + q2 * q2 - coefficient * q1 * q2
    }

    private func clamp(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }
}
