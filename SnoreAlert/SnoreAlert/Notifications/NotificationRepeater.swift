import Foundation
import UserNotifications

final class NotificationRepeater: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let queue = DispatchQueue(label: "snorealert.notification-repeater")
    private var timer: DispatchSourceTimer?

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

    func startRepeating(interval: TimeInterval) {
        stopRepeating()
        sendNotification()

        let safeInterval = max(interval, 1.5)
        let newTimer = DispatchSource.makeTimerSource(queue: queue)
        newTimer.schedule(deadline: .now() + safeInterval, repeating: safeInterval)
        newTimer.setEventHandler { [weak self] in
            self?.sendNotification()
        }
        timer = newTimer
        newTimer.resume()
    }

    func stopRepeating() {
        timer?.cancel()
        timer = nil
    }

    func sendTestNotification() {
        sendNotification(title: "Test vibracie", body: "Toto je test pre Garmin.")
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

        let request = UNNotificationRequest(
            identifier: "snore-alert-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        center.add(request)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
