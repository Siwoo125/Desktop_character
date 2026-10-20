import Foundation

/// Each pet draws a fresh move/rest plan instead of sharing a repeating beat.
struct RoamingRhythm {
    let movement: TimeInterval
    let rest: TimeInterval
    let restOnly: Bool
    var nextDelay: TimeInterval { restOnly ? rest : movement + rest }
    static var resumeDelay: TimeInterval { Double.random(in: 0.8...4.5) }
    static var retryDelay: TimeInterval { Double.random(in: 0.8...1.8) }
    static var movementDuration: TimeInterval { Double.random(in: 1.5...5.5) }

    init() { var generator = SystemRandomNumberGenerator(); self.init(using: &generator) }
    init<R: RandomNumberGenerator>(using generator: inout R) {
        movement = Double.random(in: 1.5...5.5, using: &generator)
        rest = Double.random(in: 1.2...6, using: &generator)
        restOnly = Int.random(in: 0..<10, using: &generator) < 3
    }

    static func checkIndependentTimelines() throws {
        struct Seeded: RandomNumberGenerator {
            var value: UInt64
            mutating func next() -> UInt64 { value = value &* 6364136223846793005 &+ 1442695040888963407; return value }
        }
        var generators = [Seeded(value: 13), Seeded(value: 79)]
        var deadlines = [0.0, 0.0], movingUntil = [0.0, 0.0]
        var mixed = 0, rests = [0, 0], moves = [0, 0]
        for step in 0..<2400 {
            let now = Double(step) / 20
            for index in 0..<2 where now >= deadlines[index] {
                let plan = RoamingRhythm(using: &generators[index])
                guard (1.5...5.5).contains(plan.movement), (1.2...6).contains(plan.rest) else { throw AssetError.invalid("자동 이동·휴식 시간 범위") }
                movingUntil[index] = plan.restOnly ? now : now + plan.movement
                deadlines[index] = now + plan.nextDelay
                if plan.restOnly { rests[index] += 1 } else { moves[index] += 1 }
            }
            if (now < movingUntil[0]) != (now < movingUntil[1]) { mixed += 1 }
        }
        guard mixed > 200, rests.allSatisfy({ $0 > 0 }), moves.allSatisfy({ $0 > 0 }) else { throw AssetError.invalid("각 캐릭터가 같은 시간축에서도 독립적으로 이동·휴식해야 합니다.") }
    }
}
