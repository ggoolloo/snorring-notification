import AVFoundation
import Foundation

enum SnoreEpisodeState: String {
    case idle
    case candidate
    case snoring
    case interrupted
}

struct SnoreClassificationWindow {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let snoringScore: Float?
    let speechScore: Float?
}

struct SnoreAnalysis {
    let confidence: Float
    let isSnoring: Bool
    let didStartSnoring: Bool
    let didStopSnoring: Bool
    let decibels: Float
    let lowBandRatio: Float
    let rhythmScore: Float
    let transientScore: Float
    let state: SnoreEpisodeState
    let audioTime: TimeInterval
    let eventStartAudioTime: TimeInterval?
    let lastConfirmedSnoreEndAudioTime: TimeInterval?
    let estimatedPeriod: TimeInterval?
    let effectiveStopDelay: TimeInterval
    let reason: String
}

final class SnoreDetector {
    struct SettingsSnapshot {
        let sensitivity: Float
        let stopDelay: TimeInterval
    }

    private struct FeatureFrame {
        let startTime: TimeInterval
        let endTime: TimeInterval
        let decibels: Float
        let confidence: Float
        let lowBandRatio: Float
        let transientScore: Float
        let hasAcousticSupport: Bool
    }

    private struct Pulse {
        let id: Int
        let startTime: TimeInterval
        let endTime: TimeInterval
        let peakConfidence: Float
        let averageLowBandRatio: Float
        let hadModelSupport: Bool
    }

    private var state: SnoreEpisodeState = .idle
    private var activePulseStart: TimeInterval?
    private var activePulseEnd: TimeInterval?
    private var activePulsePeakConfidence: Float = 0
    private var activePulseLowBandSum: Float = 0
    private var activePulseFrameCount = 0
    private var activePulseHadModelSupport = false
    private var acceptedPulses: [Pulse] = []
    private var classifications: [SnoreClassificationWindow] = []
    private var nextPulseID = 1
    private var noiseFloorDecibels: Float?
    private var previousDecibels: Float?
    private var estimatedPeriod: TimeInterval?
    private var rhythmScore: Float = 0
    private var lastConfirmedSnoreEnd: TimeInterval?
    private var eventStart: TimeInterval?

    func reset() {
        state = .idle
        activePulseStart = nil
        activePulseEnd = nil
        activePulsePeakConfidence = 0
        activePulseLowBandSum = 0
        activePulseFrameCount = 0
        activePulseHadModelSupport = false
        acceptedPulses = []
        classifications = []
        nextPulseID = 1
        noiseFloorDecibels = nil
        previousDecibels = nil
        estimatedPeriod = nil
        rhythmScore = 0
        lastConfirmedSnoreEnd = nil
        eventStart = nil
    }

    func markInterrupted(at audioTime: TimeInterval) -> SnoreAnalysis {
        state = .interrupted
        activePulseStart = nil
        activePulseEnd = nil

        return SnoreAnalysis(
            confidence: 0,
            isSnoring: false,
            didStartSnoring: false,
            didStopSnoring: true,
            decibels: -120,
            lowBandRatio: 0,
            rhythmScore: 0,
            transientScore: 0,
            state: state,
            audioTime: audioTime,
            eventStartAudioTime: eventStart,
            lastConfirmedSnoreEndAudioTime: lastConfirmedSnoreEnd,
            estimatedPeriod: estimatedPeriod,
            effectiveStopDelay: 0,
            reason: "Audio stream interrupted"
        )
    }

    func addClassification(_ classification: SnoreClassificationWindow) {
        classifications.append(classification)
        classifications.removeAll { classification.endTime - $0.endTime > 45 }
    }

    func analyze(
        buffer: AVAudioPCMBuffer,
        audioStartTime: TimeInterval,
        settings: SettingsSnapshot
    ) -> SnoreAnalysis {
        guard
            let channelData = buffer.floatChannelData,
            buffer.frameLength > 0
        else {
            return emptyAnalysis(at: audioStartTime, reason: "No PCM data")
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = max(1, Int(buffer.format.channelCount))
        let sampleRate = Float(buffer.format.sampleRate)
        let duration = TimeInterval(frameCount) / TimeInterval(sampleRate)
        let endTime = audioStartTime + duration

        let frame = makeFeatureFrame(
            channelData: channelData,
            channelCount: channelCount,
            frameCount: frameCount,
            sampleRate: sampleRate,
            startTime: audioStartTime,
            endTime: endTime,
            settings: settings
        )

        classifications.removeAll { endTime - $0.endTime > 45 }
        updatePulse(with: frame, settings: settings)
        pruneOldPulses(at: endTime)

        var didStart = false
        var didStop = false
        var reason = frame.hasAcousticSupport ? "Acoustic snore-like buffer" : "Waiting for snore-like pulse"

        if state == .snoring {
            let timeout = effectiveStopDelay(settings: settings)
            if let lastEnd = lastConfirmedSnoreEnd, endTime - lastEnd > timeout {
                didStop = true
                state = .idle
                eventStart = nil
                acceptedPulses.removeAll()
                estimatedPeriod = nil
                rhythmScore = 0
                reason = "No confirmed snore pulse inside timeout"
            }
        }

        if state != .snoring, acceptedPulses.count >= 3, rhythmScore >= 0.66, hasStableRecentBreathingIntervals() {
            let recent = Array(acceptedPulses.suffix(3))
            let hasThreeSupportedBreaths = recent.allSatisfy {
                $0.peakConfidence >= attackThreshold(for: settings.sensitivity)
            }

            if hasThreeSupportedBreaths {
                state = .snoring
                eventStart = recent.first?.startTime
                lastConfirmedSnoreEnd = recent.last?.endTime
                didStart = true
                reason = "Third supported breath confirmed rhythm"
            }
        } else if state == .idle, activePulseStart != nil || acceptedPulses.count > 0 {
            state = .candidate
        } else if state == .candidate, acceptedPulses.isEmpty, activePulseStart == nil {
            state = .idle
        }

        return SnoreAnalysis(
            confidence: frame.confidence,
            isSnoring: state == .snoring,
            didStartSnoring: didStart,
            didStopSnoring: didStop,
            decibels: frame.decibels,
            lowBandRatio: frame.lowBandRatio,
            rhythmScore: rhythmScore,
            transientScore: frame.transientScore,
            state: state,
            audioTime: endTime,
            eventStartAudioTime: eventStart,
            lastConfirmedSnoreEndAudioTime: lastConfirmedSnoreEnd,
            estimatedPeriod: estimatedPeriod,
            effectiveStopDelay: effectiveStopDelay(settings: settings),
            reason: reason
        )
    }

    private func emptyAnalysis(at audioTime: TimeInterval, reason: String) -> SnoreAnalysis {
        SnoreAnalysis(
            confidence: 0,
            isSnoring: state == .snoring,
            didStartSnoring: false,
            didStopSnoring: false,
            decibels: -120,
            lowBandRatio: 0,
            rhythmScore: rhythmScore,
            transientScore: 0,
            state: state,
            audioTime: audioTime,
            eventStartAudioTime: eventStart,
            lastConfirmedSnoreEndAudioTime: lastConfirmedSnoreEnd,
            estimatedPeriod: estimatedPeriod,
            effectiveStopDelay: 0,
            reason: reason
        )
    }

    private func makeFeatureFrame(
        channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int,
        sampleRate: Float,
        startTime: TimeInterval,
        endTime: TimeInterval,
        settings: SettingsSnapshot
    ) -> FeatureFrame {
        let mono = makeMonoSamples(
            channelData: channelData,
            channelCount: channelCount,
            frameCount: frameCount
        )
        let rms = rootMeanSquare(mono)
        let decibels = 20 * log10(max(rms, 0.000_001))
        let floor = updateNoiseFloor(decibels: decibels)
        let decibelJump = abs(decibels - (previousDecibels ?? decibels))
        previousDecibels = decibels

        let subBassBand = bandEnergy(samples: mono, sampleRate: sampleRate, from: 20, to: 70, step: 10)
        let snoreBand = bandEnergy(samples: mono, sampleRate: sampleRate, from: 80, to: 760, step: 40)
        let speechBand = bandEnergy(samples: mono, sampleRate: sampleRate, from: 850, to: 2_800, step: 130)
        let totalBandEnergy = max(subBassBand + snoreBand + speechBand, 0.000_001)
        let lowBandRatio = snoreBand / totalBandEnergy
        let speechRatio = speechBand / totalBandEnergy
        let subBassRatio = subBassBand / totalBandEnergy

        let overlapClassification = strongestClassification(overlappingStart: startTime, end: endTime)
        let snoreModelScore = overlapClassification.snoringScore ?? 0
        let speechModelScore = overlapClassification.speechScore ?? 0

        let prominenceScore = clamp((decibels - floor - 4) / 14)
        let bandScore = clamp((lowBandRatio - 0.30) / 0.38)
        let speechPenalty = max(
            clamp((speechRatio - 0.58) / 0.22),
            clamp((speechModelScore - 0.55) / 0.35)
        )
        let subBassPenalty = clamp((subBassRatio - 0.45) / 0.25)
        let transientScore = clamp((decibelJump - 10) / 18)
        let acousticScore = clamp(
            (0.42 * prominenceScore) +
            (0.48 * bandScore) -
            (0.22 * speechPenalty) -
            (0.20 * subBassPenalty) -
            (0.14 * transientScore)
        )

        let modelBoost = clamp((snoreModelScore - 0.30) / 0.45)
        let confidence = clamp((0.78 * acousticScore) + (0.22 * modelBoost))
        let threshold = attackThreshold(for: settings.sensitivity)
        let hasAcousticSupport = confidence >= threshold &&
            prominenceScore >= 0.18 &&
            transientScore < 0.90 &&
            (bandScore >= 0.12 || snoreModelScore >= 0.40)

        return FeatureFrame(
            startTime: startTime,
            endTime: endTime,
            decibels: decibels,
            confidence: confidence,
            lowBandRatio: lowBandRatio,
            transientScore: transientScore,
            hasAcousticSupport: hasAcousticSupport
        )
    }

    private func updatePulse(with frame: FeatureFrame, settings: SettingsSnapshot) {
        let threshold = attackThreshold(for: settings.sensitivity)
        let release = max(0.20, threshold - 0.13)
        let shouldStart = frame.hasAcousticSupport
        let shouldContinue = activePulseStart != nil && frame.confidence >= release && frame.transientScore < 0.95

        if shouldStart || shouldContinue {
            if activePulseStart == nil {
                activePulseStart = frame.startTime
                activePulsePeakConfidence = frame.confidence
                activePulseLowBandSum = 0
                activePulseFrameCount = 0
                activePulseHadModelSupport = false
            }

            activePulseEnd = frame.endTime
            activePulsePeakConfidence = max(activePulsePeakConfidence, frame.confidence)
            activePulseLowBandSum += frame.lowBandRatio
            activePulseFrameCount += 1

            if let modelSupport = strongestClassification(overlappingStart: frame.startTime, end: frame.endTime).snoringScore {
                activePulseHadModelSupport = activePulseHadModelSupport || modelSupport >= 0.40
            }

            return
        }

        finalizeActivePulse(settings: settings)
    }

    private func finalizeActivePulse(settings: SettingsSnapshot) {
        guard
            let start = activePulseStart,
            let end = activePulseEnd
        else {
            clearActivePulse()
            return
        }

        defer { clearActivePulse() }

        let duration = end - start
        let averageLowBandRatio = activePulseLowBandSum / Float(max(activePulseFrameCount, 1))
        let threshold = attackThreshold(for: settings.sensitivity)

        guard duration >= 0.24, duration <= 2.8, activePulsePeakConfidence >= threshold else {
            return
        }

        if let previous = acceptedPulses.last, start - previous.endTime < 0.75 {
            let merged = Pulse(
                id: previous.id,
                startTime: previous.startTime,
                endTime: end,
                peakConfidence: max(previous.peakConfidence, activePulsePeakConfidence),
                averageLowBandRatio: max(previous.averageLowBandRatio, averageLowBandRatio),
                hadModelSupport: previous.hadModelSupport || activePulseHadModelSupport
            )
            acceptedPulses.removeLast()
            acceptedPulses.append(merged)
            recomputeRhythm()
            return
        }

        let pulse = Pulse(
            id: nextPulseID,
            startTime: start,
            endTime: end,
            peakConfidence: activePulsePeakConfidence,
            averageLowBandRatio: averageLowBandRatio,
            hadModelSupport: activePulseHadModelSupport
        )
        nextPulseID += 1

        appendAcceptedPulse(pulse)
    }

    private func appendAcceptedPulse(_ pulse: Pulse) {
        if let previous = acceptedPulses.last {
            let interval = pulse.startTime - previous.startTime
            let isBreathingInterval = interval >= 1.5 && interval <= 8.5

            if !isBreathingInterval {
                acceptedPulses = [pulse]
                estimatedPeriod = nil
                rhythmScore = 0
            } else if let period = estimatedPeriod, abs(interval - period) / max(period, 0.1) > 0.48 {
                acceptedPulses = [previous, pulse]
                estimatedPeriod = interval
                rhythmScore = 0.35
            } else {
                acceptedPulses.append(pulse)
                recomputeRhythm()
            }
        } else {
            acceptedPulses.append(pulse)
            rhythmScore = 0
        }

        if state == .snoring {
            lastConfirmedSnoreEnd = pulse.endTime
        }
    }

    private func recomputeRhythm() {
        guard acceptedPulses.count >= 2 else {
            estimatedPeriod = nil
            rhythmScore = 0
            return
        }

        let recent = Array(acceptedPulses.suffix(5))
        let intervals = zip(recent.dropFirst(), recent).map { current, previous in
            current.startTime - previous.startTime
        }
        let validIntervals = intervals.filter { $0 >= 1.5 && $0 <= 8.5 }

        guard validIntervals.count == intervals.count, validIntervals.count >= 1 else {
            rhythmScore = 0
            return
        }

        let medianInterval = median(validIntervals)
        let deviations = validIntervals.map { abs($0 - medianInterval) / max(medianInterval, 0.1) }
        let medianDeviation = median(deviations)
        let countScore = clamp(Float(validIntervals.count) / 2)
        let consistencyScore = clamp(1 - Float(medianDeviation / 0.42))
        let tempoScore: Float

        if medianInterval >= 2.0 && medianInterval <= 7.0 {
            tempoScore = 1
        } else {
            let edgeDistance = min(abs(medianInterval - 2.0), abs(medianInterval - 7.0))
            tempoScore = clamp(1 - Float(edgeDistance / 1.5))
        }

        estimatedPeriod = medianInterval
        rhythmScore = clamp((0.48 * countScore) + (0.38 * consistencyScore) + (0.14 * tempoScore))
    }

    private func hasStableRecentBreathingIntervals() -> Bool {
        guard acceptedPulses.count >= 3 else {
            return false
        }

        let recent = Array(acceptedPulses.suffix(3))
        let firstInterval = recent[1].startTime - recent[0].startTime
        let secondInterval = recent[2].startTime - recent[1].startTime
        guard firstInterval >= 1.5, firstInterval <= 8.5, secondInterval >= 1.5, secondInterval <= 8.5 else {
            return false
        }

        let center = max((firstInterval + secondInterval) / 2, 0.1)
        return abs(firstInterval - secondInterval) / center <= 0.38
    }

    private func pruneOldPulses(at audioTime: TimeInterval) {
        acceptedPulses.removeAll { audioTime - $0.endTime > 30 }

        if acceptedPulses.isEmpty, state == .candidate {
            state = .idle
            estimatedPeriod = nil
            rhythmScore = 0
        }
    }

    private func clearActivePulse() {
        activePulseStart = nil
        activePulseEnd = nil
        activePulsePeakConfidence = 0
        activePulseLowBandSum = 0
        activePulseFrameCount = 0
        activePulseHadModelSupport = false
    }

    private func effectiveStopDelay(settings: SettingsSnapshot) -> TimeInterval {
        let base = max(settings.stopDelay, 7)

        guard let estimatedPeriod else {
            return min(max(base, 7), 15)
        }

        return min(max(max(base, 1.8 * estimatedPeriod), 7), 15)
    }

    private func attackThreshold(for sensitivity: Float) -> Float {
        let normalizedSensitivity = clamp((sensitivity - 0.45) / (0.92 - 0.45))
        return 0.74 - (0.22 * normalizedSensitivity)
    }

    private func updateNoiseFloor(decibels: Float) -> Float {
        guard let current = noiseFloorDecibels else {
            let initial = min(decibels, -50)
            noiseFloorDecibels = initial
            return initial
        }

        let isEpisodeActive = state == .candidate || state == .snoring || activePulseStart != nil
        let upwardRate: Float = isEpisodeActive ? 0.001 : 0.006
        let downwardRate: Float = 0.12
        let rate = decibels < current ? downwardRate : upwardRate
        let updated = (current * (1 - rate)) + (decibels * rate)
        noiseFloorDecibels = min(updated, decibels - 1)
        return noiseFloorDecibels ?? updated
    }

    private func strongestClassification(overlappingStart start: TimeInterval, end: TimeInterval) -> (snoringScore: Float?, speechScore: Float?) {
        let overlapping = classifications.filter { window in
            window.endTime >= start && window.startTime <= end
        }

        guard !overlapping.isEmpty else {
            return (nil, nil)
        }

        let snoreScore = overlapping.compactMap(\.snoringScore).max()
        let speechScore = overlapping.compactMap(\.speechScore).max()
        return (snoreScore, speechScore)
    }

    private func makeMonoSamples(
        channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int
    ) -> [Float] {
        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        }

        var samples = Array(repeating: Float(0), count: frameCount)
        let channelScale = Float(channelCount)

        for channel in 0..<channelCount {
            let source = UnsafeBufferPointer(start: channelData[channel], count: frameCount)
            for index in 0..<frameCount {
                samples[index] += source[index] / channelScale
            }
        }

        return samples
    }

    private func rootMeanSquare(_ samples: [Float]) -> Float {
        var sum: Float = 0

        for sample in samples {
            sum += sample * sample
        }

        return sqrt(sum / Float(max(samples.count, 1)))
    }

    private func bandEnergy(
        samples: [Float],
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
        var count: Float = 0

        while frequency <= endFrequency {
            energy += goertzelPower(samples: samples, sampleRate: sampleRate, frequency: frequency)
            frequency += step
            count += 1
        }

        return energy / max(count, 1)
    }

    private func goertzelPower(
        samples: [Float],
        sampleRate: Float,
        frequency: Float
    ) -> Float {
        let normalizedFrequency = frequency / sampleRate
        let coefficient = 2 * cos(2 * Float.pi * normalizedFrequency)
        var q0: Float = 0
        var q1: Float = 0
        var q2: Float = 0
        let denominator = Float(max(samples.count - 1, 1))

        for (index, sample) in samples.enumerated() {
            let window = 0.5 - (0.5 * cos((2 * Float.pi * Float(index)) / denominator))
            q0 = coefficient * q1 - q2 + (sample * window)
            q2 = q1
            q1 = q0
        }

        return max(q1 * q1 + q2 * q2 - coefficient * q1 * q2, 0)
    }

    private func median(_ values: [TimeInterval]) -> TimeInterval {
        guard !values.isEmpty else {
            return 0
        }

        let sorted = values.sorted()
        let middle = sorted.count / 2

        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }

        return sorted[middle]
    }

    private func clamp(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }
}
