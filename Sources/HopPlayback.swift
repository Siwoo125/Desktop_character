import Foundation

enum HopKind { case upward, downward }

enum HopAction {
    case onto(Ledge)
    case inPlace(CGFloat)
    case down

    var kind: HopKind {
        switch self { case .onto, .inPlace: return .upward; case .down: return .downward }
    }
}

/// Each row is a four-pose sequence, driven by takeoff and actual ground contact.
struct HopPlayback {
    enum Phase: Int { case preparing, airborne, beforeLanding, landing }
    static let preparationDuration: TimeInterval = 0.16
    static let landingDuration: TimeInterval = 0.20
    let kind: HopKind
    private(set) var phase: Phase
    private(set) var phaseTime: TimeInterval = 0

    init(kind: HopKind, alreadyAirborne: Bool = false) {
        self.kind = kind
        phase = alreadyAirborne ? .airborne : .preparing
    }

    var frameIndex: Int { phase.rawValue }
    var readyToLaunch: Bool { phase == .preparing && phaseTime >= Self.preparationDuration }
    var finished: Bool { phase == .landing && phaseTime >= Self.landingDuration }
    var holdsHorizontalMotion: Bool { phase == .preparing || phase == .landing }

    mutating func advanceClock(by delta: TimeInterval) { phaseTime += max(0, delta) }

    mutating func launched() { transition(to: .airborne) }

    mutating func observe(grounded: Bool, landingSoon: Bool) {
        guard phase != .preparing else { return }
        if phase == .landing { return }
        if phase == .airborne && (landingSoon || grounded) {
            transition(to: .beforeLanding)
        } else if phase == .beforeLanding && grounded && phaseTime >= 0.04 {
            transition(to: .landing)
        } else if phase == .beforeLanding && !grounded && !landingSoon {
            // A destination window disappeared or moved away: stay airborne.
            transition(to: .airborne)
        }
    }

    private mutating func transition(to next: Phase) {
        phase = next
        phaseTime = 0
    }
}
