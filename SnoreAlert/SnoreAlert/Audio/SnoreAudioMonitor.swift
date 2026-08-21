import AVFoundation
import Combine
import Foundation

final class SnoreAudioMonitor: ObservableObject {
    enum ListeningState: Equatable {
        case idle
        case starting
        case listening
        case failed(String)
    }

    @Published private(set) var state: ListeningState = .idle
    @Published private(set) var isSnoring = false
    @Published private(set) var confidence: Float = 0
    @Published private(set) var decibels: Float = -120
    @Published private(set) var lowBandRatio: Float = 0
    @Published private(set) var events: [SnoreEvent] = []

    private let settings: AppSettings
    private let detector = SnoreDetector()
    private let notifications = NotificationRepeater()
    private let engine = AVAudioEngine()
    private var lastSnoringAt: Date?
    private var activeEvent: SnoreEvent?

    init(settings: AppSettings) {
        self.settings = settings
    }

    var isListening: Bool {
        if case .listening = state {
            return true
        }
        return false
    }

    func start() async {
        await MainActor.run {
            state = .starting
        }

        guard await requestMicrophoneAccess() else {
            await MainActor.run {
                state = .failed("Mikrofon nie je povoleny.")
            }
            return
        }

        guard await notifications.requestAuthorization() else {
            await MainActor.run {
                state = .failed("Notifikacie nie su povolene.")
            }
            return
        }

        do {
            try configureAudioSession()
            try startEngine()

            await MainActor.run {
                state = .listening
            }
        } catch {
            await MainActor.run {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        detector.reset()
        notifications.stopRepeating()
        closeActiveEvent(at: Date())

        DispatchQueue.main.async {
            self.isSnoring = false
            self.confidence = 0
            self.state = .idle
        }
    }

    func sendTestNotification() {
        notifications.sendTestNotification()
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
        try session.setActive(true)
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        detector.reset()
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }

        engine.prepare()
        try engine.start()
    }

    private func process(buffer: AVAudioPCMBuffer) {
        let analysis = detector.analyze(buffer: buffer, settings: settings)
        let now = Date()

        DispatchQueue.main.async {
            self.confidence = analysis.confidence
            self.decibels = analysis.decibels
            self.lowBandRatio = analysis.lowBandRatio
            self.updateSnoringState(isDetected: analysis.isSnoring, at: now)
        }
    }

    private func updateSnoringState(isDetected: Bool, at date: Date) {
        if isDetected {
            lastSnoringAt = date

            if !isSnoring {
                isSnoring = true
                activeEvent = SnoreEvent(startedAt: date, peakConfidence: confidence)
                notifications.startRepeating(interval: settings.repeatInterval)
            } else if var event = activeEvent {
                event.peakConfidence = max(event.peakConfidence, confidence)
                activeEvent = event
            }

            return
        }

        guard isSnoring else {
            return
        }

        let elapsedSinceLastSnore = date.timeIntervalSince(lastSnoringAt ?? date)
        if elapsedSinceLastSnore >= settings.stopDelay {
            isSnoring = false
            notifications.stopRepeating()
            closeActiveEvent(at: date)
        }
    }

    private func closeActiveEvent(at date: Date) {
        guard var event = activeEvent else {
            return
        }

        event.endedAt = date
        events.insert(event, at: 0)
        activeEvent = nil
    }

    private func requestMicrophoneAccess() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}
