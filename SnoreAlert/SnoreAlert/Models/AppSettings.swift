import Combine
import Foundation

final class AppSettings: ObservableObject {
    private enum Keys {
        static let sensitivity = "sensitivity"
        static let repeatInterval = "repeatInterval"
        static let stopDelay = "stopDelay"
        static let settingsVersion = "settingsVersion"
    }

    @Published var sensitivity: Float {
        didSet { UserDefaults.standard.set(sensitivity, forKey: Keys.sensitivity) }
    }

    @Published var repeatInterval: Double {
        didSet { UserDefaults.standard.set(repeatInterval, forKey: Keys.repeatInterval) }
    }

    @Published var stopDelay: Double {
        didSet { UserDefaults.standard.set(stopDelay, forKey: Keys.stopDelay) }
    }

    var detectorSettings: SnoreDetector.SettingsSnapshot {
        SnoreDetector.SettingsSnapshot(
            sensitivity: sensitivity,
            stopDelay: stopDelay
        )
    }

    init() {
        let storedVersion = UserDefaults.standard.integer(forKey: Keys.settingsVersion)
        let storedSensitivity = UserDefaults.standard.object(forKey: Keys.sensitivity) as? Float

        if storedVersion == 0, let oldThreshold = storedSensitivity {
            sensitivity = min(max(1.37 - oldThreshold, 0.45), 0.92)
            UserDefaults.standard.set(sensitivity, forKey: Keys.sensitivity)
            UserDefaults.standard.set(2, forKey: Keys.settingsVersion)
        } else {
            sensitivity = storedSensitivity ?? 0.72
            UserDefaults.standard.set(2, forKey: Keys.settingsVersion)
        }

        repeatInterval = UserDefaults.standard.object(forKey: Keys.repeatInterval) as? Double ?? 3.0
        stopDelay = UserDefaults.standard.object(forKey: Keys.stopDelay) as? Double ?? 7.0
    }
}
