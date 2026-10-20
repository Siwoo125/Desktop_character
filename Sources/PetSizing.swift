import Foundation

struct PetSizing {
    static let scales: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]
    let baseHeight: CGFloat
    var scale: Double
    var height: CGFloat { baseHeight * CGFloat(scale) }

    init(savedBase: Double, savedScale: Double, legacyHeight: Double) {
        if savedBase.isFinite, (20...160).contains(savedBase) {
            baseHeight = CGFloat(savedBase)
            scale = Self.scales.contains(savedScale) ? savedScale : 1
        } else {
            // Halve the user's actual old size once, then retain the new base on relaunch.
            let previous = [120.0, 160.0, 220.0].contains(legacyHeight) ? legacyHeight : 160
            baseHeight = CGFloat(previous / 2)
            scale = 1
        }
    }
}

enum GroundGait: CaseIterable {
    case walking, running

    static func randomForRoaming() -> GroundGait {
        Int.random(in: 0..<10) < 4 ? .running : .walking
    }

    var speed: CGFloat { self == .running ? 180 : 90 }
    var frameDuration: TimeInterval { self == .running ? 0.065 : 0.10 }
    func frameIndex(at time: TimeInterval) -> Int { Int(max(0, time) / frameDuration) % 8 }
}
