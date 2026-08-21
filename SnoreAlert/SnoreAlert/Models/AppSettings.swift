import Combine
import Foundation

final class AppSettings: ObservableObject {
    private enum Keys {
        static let sensitivity = "sensitivity"
        static let repeatInterval = "repeatInterval"
        static let stopDelay = "stopDelay"
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

    let requiredPositiveWindows = 2

    init() {
        sensitivity = UserDefaults.standard.object(forKey: Keys.sensitivity) as? Float ?? 0.72
        repeatInterval = UserDefaults.standard.object(forKey: Keys.repeatInterval) as? Double ?? 3.0
        stopDelay = UserDefaults.standard.object(forKey: Keys.stopDelay) as? Double ?? 4.0
    }
}
