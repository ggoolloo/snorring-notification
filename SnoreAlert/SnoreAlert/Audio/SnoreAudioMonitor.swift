import AVFoundation
import Combine
import Foundation
import SoundAnalysis

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
    @Published private(set) var rhythmScore: Float = 0
    @Published private(set) var effectiveStopDelay: TimeInterval = 7
    @Published private(set) var detectionReason = ""
    @Published private(set) var events: [SnoreEvent] = []

    private let settings: AppSettings
    private let detector = SnoreDetector()
    private let notifications = NotificationRepeater()
    private let engine = AVAudioEngine()
    private let analysisQueue = DispatchQueue(label: "snorealert.audio-analysis")
    private let lock = NSLock()

    private var settingsSnapshot: SnoreDetector.SettingsSnapshot
    private var settingsCancellable: AnyCancellable?
    private var sessionGeneration = 0
    private var sessionStartAudioTime: TimeInterval = 0
    private var sessionStartDate = Date()
    private var notificationValidUntil: Date?
    private var activeEvent: SnoreEvent?
    private var soundAnalyzer: SNAudioStreamAnalyzer?
    private var soundRequest: SNClassifySoundRequest?
    private var soundObserver: SoundClassifierObserver?
    private var hasSnoringClassification = false

    init(settings: AppSettings) {
        self.settings = settings
        self.settingsSnapshot = settings.detectorSettings

        settingsCancellable = Publishers.CombineLatest3(
            settings.$sensitivity,
            settings.$repeatInterval,
            settings.$stopDelay
        )
        .sink { [weak self] _, _, _ in
            guard let self else {
                return
            }

            let snapshot = settings.detectorSettings
            self.analysisQueue.async {
                self.settingsSnapshot = snapshot
            }
        }

        registerAudioNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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
            let generation = nextSessionGeneration()
            try startEngine(generation: generation)

            await MainActor.run {
                state = .listening
            }
        } catch {
            notifications.stopRepeating()
            await MainActor.run {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func stop() {
        _ = nextSessionGeneration()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        notifications.stopRepeating()
        setNotificationValidity(until: nil)

        analysisQueue.async { [weak self] in
            self?.soundAnalyzer = nil
            self?.soundRequest = nil
            self?.soundObserver = nil
            self?.hasSnoringClassification = false
            self?.detector.reset()
        }

        DispatchQueue.main.async {
            self.closeActiveEvent(at: Date())
            self.isSnoring = false
            self.confidence = 0
            self.rhythmScore = 0
            self.effectiveStopDelay = self.settings.stopDelay
            self.detectionReason = ""
            self.state = .idle
        }
    }

    func sendTestNotification() {
        notifications.sendTestNotification()
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true)
    }

    private func startEngine(generation: Int) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        guard format.commonFormat == .pcmFormatFloat32 else {
            throw SnoreAudioError.unsupportedInputFormat
        }

        sessionStartDate = Date()
        sessionStartAudioTime = 0

        analysisQueue.sync {
            settingsSnapshot = settings.detectorSettings
            detector.reset()
            configureSoundAnalysis(format: format)
        }

        input.removeTap(onBus: 0)

        var fallbackFramePosition: AVAudioFramePosition = 0
        input.installTap(onBus: 0, bufferSize: 8_192, format: format) { [weak self] buffer, time in
            guard let self else {
                return
            }

            let framePosition: AVAudioFramePosition
            if time.isSampleTimeValid {
                framePosition = time.sampleTime
            } else {
                framePosition = fallbackFramePosition
            }
            fallbackFramePosition = framePosition + AVAudioFramePosition(buffer.frameLength)

            guard let ownedBuffer = self.copyBuffer(buffer) else {
                return
            }

            self.analysisQueue.async { [weak self] in
                self?.process(
                    buffer: ownedBuffer,
                    framePosition: framePosition,
                    generation: generation
                )
            }
        }

        engine.prepare()
        try engine.start()
    }

    private func process(
        buffer: AVAudioPCMBuffer,
        framePosition: AVAudioFramePosition,
        generation: Int
    ) {
        guard generation == currentSessionGeneration() else {
            return
        }

        soundAnalyzer?.analyze(buffer, atAudioFramePosition: framePosition)

        let audioStartTime = TimeInterval(framePosition) / buffer.format.sampleRate
        let analysis = detector.analyze(
            buffer: buffer,
            audioStartTime: audioStartTime,
            settings: settingsSnapshot
        )

        DispatchQueue.main.async { [weak self] in
            self?.publish(analysis: analysis, generation: generation)
        }
    }

    private func publish(analysis: SnoreAnalysis, generation: Int) {
        guard generation == currentSessionGeneration() else {
            return
        }

        confidence = analysis.confidence
        decibels = analysis.decibels
        lowBandRatio = analysis.lowBandRatio
        rhythmScore = analysis.rhythmScore
        effectiveStopDelay = analysis.effectiveStopDelay
        detectionReason = analysis.reason
        updateSnoringState(analysis: analysis, generation: generation)
    }

    private func updateSnoringState(analysis: SnoreAnalysis, generation: Int) {
        let eventDate = wallDate(forAudioTime: analysis.eventStartAudioTime ?? analysis.audioTime)
        let lastSnoreDate = wallDate(forAudioTime: analysis.lastConfirmedSnoreEndAudioTime ?? analysis.audioTime)

        if analysis.didStartSnoring {
            isSnoring = true
            activeEvent = SnoreEvent(startedAt: eventDate, peakConfidence: confidence)
            refreshNotificationValidity(from: lastSnoreDate, analysis: analysis)

            notifications.startRepeating(interval: settings.repeatInterval) { [weak self] in
                self?.canSendNotification(for: generation) ?? false
            }
            return
        }

        if analysis.isSnoring {
            refreshNotificationValidity(from: lastSnoreDate, analysis: analysis)

            if var event = activeEvent {
                event.peakConfidence = max(event.peakConfidence, confidence)
                activeEvent = event
            }

            isSnoring = true
            return
        }

        if isSnoring || analysis.didStopSnoring {
            isSnoring = false
            notifications.stopRepeating()
            setNotificationValidity(until: nil)
            closeActiveEvent(at: wallDate(forAudioTime: analysis.audioTime))
        }
    }

    private func refreshNotificationValidity(from lastSnoreDate: Date, analysis: SnoreAnalysis) {
        let validUntil = lastSnoreDate.addingTimeInterval(analysis.effectiveStopDelay + settings.repeatInterval + 1)
        setNotificationValidity(until: validUntil)
    }

    private func closeActiveEvent(at date: Date) {
        guard var event = activeEvent else {
            return
        }

        event.endedAt = date
        events.insert(event, at: 0)
        activeEvent = nil
    }

    private func wallDate(forAudioTime audioTime: TimeInterval) -> Date {
        sessionStartDate.addingTimeInterval(audioTime - sessionStartAudioTime)
    }

    private func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard
            let sourceData = buffer.floatChannelData,
            let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else {
            return nil
        }

        copy.frameLength = buffer.frameLength
        guard let targetData = copy.floatChannelData else {
            return nil
        }

        let byteCount = Int(buffer.frameLength) * MemoryLayout<Float>.size
        for channel in 0..<Int(buffer.format.channelCount) {
            memcpy(targetData[channel], sourceData[channel], byteCount)
        }

        return copy
    }

    private func configureSoundAnalysis(format: AVAudioFormat) {
        soundAnalyzer = nil
        soundRequest = nil
        soundObserver = nil
        hasSnoringClassification = false

        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(seconds: 1, preferredTimescale: 1_000)
            request.overlapFactor = 0.5

            let labels = request.knownClassifications.map { $0.lowercased() }
            hasSnoringClassification = labels.contains { $0.contains("snor") }

            let observer = SoundClassifierObserver { [weak self] result in
                self?.handleClassification(result)
            }

            let analyzer = SNAudioStreamAnalyzer(format: format)
            try analyzer.add(request, withObserver: observer)

            soundRequest = request
            soundObserver = observer
            soundAnalyzer = analyzer

            if !hasSnoringClassification {
                NSLog("SnoreAlert SoundAnalysis has no snoring label on this OS; using acoustic rhythm only.")
            }
        } catch {
            NSLog("SnoreAlert SoundAnalysis unavailable: \(error.localizedDescription)")
        }
    }

    private func handleClassification(_ result: SNClassificationResult) {
        let snoring = result.classifications
            .filter { $0.identifier.lowercased().contains("snor") }
            .map(\.confidence)
            .max()

        let speech = result.classifications
            .filter { classification in
                let label = classification.identifier.lowercased()
                return label.contains("speech") || label.contains("talk") || label.contains("conversation")
            }
            .map(\.confidence)
            .max()

        let start = result.timeRange.start.seconds
        let end = result.timeRange.end.seconds

        detector.addClassification(
            SnoreClassificationWindow(
                startTime: start,
                endTime: end,
                snoringScore: snoring.map(Float.init),
                speechScore: speech.map(Float.init)
            )
        )
    }

    private func registerAudioNotifications() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleAudioInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        center.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
        center.addObserver(
            self,
            selector: #selector(handleMediaServicesReset),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc private func handleAudioInterruption(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.stopAfterAudioProblem(message: "Audio bolo prerusene.")
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard isListening else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.stopAfterAudioProblem(message: "Zmenil sa vstup mikrofonu. Spusti pocuvanie znova.")
        }
    }

    @objc private func handleMediaServicesReset(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.stopAfterAudioProblem(message: "Audio sluzby iOS sa resetovali.")
        }
    }

    private func stopAfterAudioProblem(message: String) {
        let generation = nextSessionGeneration()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        notifications.stopRepeating()
        setNotificationValidity(until: nil)

        analysisQueue.async { [weak self] in
            _ = self?.detector.markInterrupted(at: 0)
        }

        closeActiveEvent(at: Date())
        isSnoring = false
        state = .failed(message)
        confidence = 0
        rhythmScore = 0
        detectionReason = "Session \(generation) stopped: \(message)"
    }

    private func requestMicrophoneAccess() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    private func nextSessionGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        sessionGeneration += 1
        return sessionGeneration
    }

    private func currentSessionGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return sessionGeneration
    }

    private func setNotificationValidity(until date: Date?) {
        lock.lock()
        notificationValidUntil = date
        lock.unlock()
    }

    private func canSendNotification(for generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard generation == sessionGeneration, let notificationValidUntil else {
            return false
        }

        return Date() <= notificationValidUntil
    }
}

private final class SoundClassifierObserver: NSObject, SNResultsObserving {
    private let onResult: (SNClassificationResult) -> Void

    init(onResult: @escaping (SNClassificationResult) -> Void) {
        self.onResult = onResult
        super.init()
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classification = result as? SNClassificationResult else {
            return
        }

        onResult(classification)
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        NSLog("SnoreAlert sound classification failed: \(error.localizedDescription)")
    }
}

private enum SnoreAudioError: LocalizedError {
    case unsupportedInputFormat

    var errorDescription: String? {
        switch self {
        case .unsupportedInputFormat:
            return "Audio vstup nie je vo formate Float32 PCM."
        }
    }
}
