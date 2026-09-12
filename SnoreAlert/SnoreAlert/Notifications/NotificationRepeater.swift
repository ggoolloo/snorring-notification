import Foundation
import UserNotifications

final class NotificationRepeater: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let queue = DispatchQueue(label: "snorealert.notification-repeater")
    private var timer: DispatchSourceTimer?
    private var generation = 0
    private var ownedRequestIdentifiers: [String] = []

    override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .badge])
        } catch {
            return false
        }
    }

    func startRepeating(
        interval: TimeInterval,
        shouldContinue: @escaping () -> Bool
    ) {
        queue.async { [weak self] in
            guard let self else {
                return
            }

            self.generation += 1
            let currentGeneration = self.generation
            self.timer?.cancel()
            self.timer = nil

            self.sendNotificationIfValid(generation: currentGeneration, shouldContinue: shouldContinue)

            let safeInterval = max(interval, 1.5)
            let newTimer = DispatchSource.makeTimerSource(queue: self.queue)
            newTimer.schedule(deadline: .now() + safeInterval, repeating: safeInterval)
            newTimer.setEventHandler { [weak self] in
                self?.sendNotificationIfValid(generation: currentGeneration, shouldContinue: shouldContinue)
            }
            self.timer = newTimer
            newTimer.resume()
        }
    }

    func stopRepeating() {
        queue.async { [weak self] in
            guard let self else {
                return
            }

            self.generation += 1
            self.timer?.cancel()
            self.timer = nil

            let identifiers = self.ownedRequestIdentifiers
            self.ownedRequestIdentifiers.removeAll()
            self.center.removePendingNotificationRequests(withIdentifiers: identifiers)
        }
    }

    func sendTestNotification() {
        sendNotification(title: "Test vibracie", body: "Toto je test pre Garmin.")
    }

    private func sendNotificationIfValid(
        generation expectedGeneration: Int,
        shouldContinue: () -> Bool
    ) {
        guard generation == expectedGeneration, shouldContinue() else {
            timer?.cancel()
            timer = nil
            return
        }

        sendNotification()
    }

    private func sendNotification(
        title: String = "Zachytene chrapanie",
        body: String = "SnoreAlert pocuje chrapanie."
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        content.threadIdentifier = "snore-alert"

        let identifier = "snore-alert-\(UUID().uuidString)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        queue.async { [weak self] in
            self?.ownedRequestIdentifiers.append(identifier)
        }

        center.add(request) { error in
            if let error {
                NSLog("SnoreAlert notification request failed: \(error.localizedDescription)")
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
