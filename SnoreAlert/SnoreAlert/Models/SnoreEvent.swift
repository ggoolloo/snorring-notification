import Foundation

struct SnoreEvent: Identifiable, Equatable {
    let id = UUID()
    let startedAt: Date
    var endedAt: Date?
    var peakConfidence: Float

    var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }
}

