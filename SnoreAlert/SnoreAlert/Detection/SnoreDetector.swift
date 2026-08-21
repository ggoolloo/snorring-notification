import AVFoundation
import Foundation

struct SnoreAnalysis {
    let confidence: Float
    let isSnoring: Bool
    let decibels: Float
    let lowBandRatio: Float
}

final class SnoreDetector {
    private var positiveWindows = 0
    private var lastPositiveAt: Date?

    func reset() {
        positiveWindows = 0
        lastPositiveAt = nil
    }

    func analyze(buffer: AVAudioPCMBuffer, settings: AppSettings) -> SnoreAnalysis {
        guard
            let channelData = buffer.floatChannelData?[0],
            buffer.frameLength > 0
        else {
            return SnoreAnalysis(confidence: 0, isSnoring: false, decibels: -120, lowBandRatio: 0)
        }

        let frameCount = Int(buffer.frameLength)
        let sampleRate = Float(buffer.format.sampleRate)
        let samples = UnsafeBufferPointer(start: channelData, count: frameCount)

        let rms = rootMeanSquare(samples)
        let decibels = 20 * log10(max(rms, 0.000_001))

        let lowBand = bandEnergy(samples: samples, sampleRate: sampleRate, from: 45, to: 350, step: 25)
        let upperBand = bandEnergy(samples: samples, sampleRate: sampleRate, from: 350, to: 1_800, step: 75)
        let lowBandRatio = lowBand / max(lowBand + upperBand, 0.000_001)

        let volumeScore = clamp((decibels + 55) / 30)
        let bandScore = clamp((lowBandRatio - 0.42) / 0.38)
        let confidence = clamp((0.45 * volumeScore) + (0.55 * bandScore))

        if confidence >= settings.sensitivity {
            positiveWindows += 1
            lastPositiveAt = Date()
        } else {
            positiveWindows = max(0, positiveWindows - 1)
        }

        let isSnoring = positiveWindows >= settings.requiredPositiveWindows
        return SnoreAnalysis(
            confidence: confidence,
            isSnoring: isSnoring,
            decibels: decibels,
            lowBandRatio: lowBandRatio
        )
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

