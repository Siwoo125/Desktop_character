import Foundation

enum ClimbStep {
    case jump(Ledge)
    case approach(CGFloat)
    case finished
}

enum ClimbPlanner {
    static func nextStep(for physics: PetPhysics, completedWindows: Set<UInt64> = []) -> ClimbStep {
        let minimumWidth = physics.footHalfWidth * 2 + 8
        let tops = physics.ledges.filter {
            $0.edge == .upper && $0.y > physics.feet.y + 16 &&
            !completedWindows.contains($0.id / 2) &&
            $0.y < physics.ceiling - 4 && $0.maxX - $0.minX > minimumWidth
        }
        // A window's top defines its height. Visit the lowest remaining window first,
        // even if a taller window happens to be horizontally closer to the dog.
        guard let nextWindow = tops.min(by: {
            if abs($0.y - $1.y) > 0.01 { return $0.y < $1.y }
            return distance(to: $0, from: physics.feet.x) < distance(to: $1, from: physics.feet.x)
        }) else { return .finished }
        let windowID = nextWindow.id / 2
        let steps = physics.ledges.filter {
            $0.id / 2 == windowID && $0.edge != .ground &&
            $0.y > physics.feet.y + 16 && $0.y < physics.ceiling - 4 &&
            $0.maxX - $0.minX > minimumWidth
        }.sorted {
            if abs($0.y - $1.y) > 0.01 { return $0.y < $1.y }
            return distance(to: $0, from: physics.feet.x) < distance(to: $1, from: physics.feet.x)
        }
        guard let lowest = steps.first else { return .finished }
        // Occlusion can split the same rim; try all exposed parts of this height.
        for ledge in steps where abs(ledge.y - lowest.y) < 0.01 {
            var probe = physics
            if probe.jump(to: ledge) { return .jump(ledge) }
        }
        let inset = min(physics.footHalfWidth + 8, (lowest.maxX - lowest.minX) / 2)
        let targetX = min(lowest.maxX - inset, max(lowest.minX + inset, physics.feet.x))
        return .approach(targetX)
    }

    private static func distance(to ledge: Ledge, from x: CGFloat) -> CGFloat {
        max(ledge.minX - x, x - ledge.maxX, 0)
    }
}
