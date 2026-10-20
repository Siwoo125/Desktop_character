import Foundation

/// A resting pose followed by one row-major eight-frame animation, then rest again.
struct IdlePlayback {
    static let frameDurations: [TimeInterval] = [0.16, 0.14, 0.09, 0.14, 0.09, 0.14, 0.14, 0.18]
    private(set) var frameIndex: Int? = nil

    mutating func advance() {
        if let current = frameIndex {
            frameIndex = current == 7 ? nil : current + 1
        } else {
            frameIndex = 0
        }
    }

    mutating func rest() { frameIndex = nil }
    mutating func playNow() { frameIndex = 0 }

    var nextDelay: TimeInterval {
        if let frameIndex { return Self.frameDurations[frameIndex] }
        return Double.random(in: 3.5...6.5)
    }
}
