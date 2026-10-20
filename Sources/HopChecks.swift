import Foundation

enum HopChecks {
    static func run() throws {
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw AssetError.invalid("도약 검사: \(message)") }
        }
        let area = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let ledge = Ledge(id: 2, edge: .upper, minX: 200, maxX: 800, y: 300,
                          carrierOrigin: CGPoint(x: 200, y: 100))
        for kind in [HopKind.upward, .downward] {
            var physics = PetPhysics(feet: CGPoint(x: 500, y: kind == .upward ? 0 : 300),
                                     area: area, bodyHeight: 160)
            physics.updateLedges([ledge])
            physics.advance(by: 1.0 / 120)
            var animation = HopPlayback(kind: kind)
            var phases = [animation.frameIndex]
            var launched = false
            var showedBeforeLandingInAir = false
            var sawContact = false
            let initialY = physics.feet.y
            for _ in 0..<300 {
                let dt = 1.0 / 60
                animation.advanceClock(by: dt)
                if !launched && animation.readyToLaunch {
                    if kind == .upward { try check(physics.jump(to: ledge), "발판으로 도약") }
                    else { physics.dropDown() }
                    animation.launched()
                    launched = true
                }
                if !launched { try check(physics.feet.y == initialY, "준비 모션 동안 발 위치 유지") }
                animation.observe(grounded: physics.grounded, landingSoon: physics.willLandSoon())
                if animation.phase == .beforeLanding && !physics.grounded { showedBeforeLandingInAir = true }
                physics.advance(by: dt)
                animation.observe(grounded: physics.grounded, landingSoon: physics.willLandSoon())
                if animation.phase == .landing {
                    try check(physics.grounded, "착지 모션은 실제 접촉 후 표시")
                    sawContact = true
                }
                if phases.last != animation.frameIndex { phases.append(animation.frameIndex) }
                if animation.finished { break }
            }
            try check(phases == [0, 1, 2, 3], "준비 → 공중 → 착지 직전 → 착지 순서")
            try check(showedBeforeLandingInAir && sawContact && animation.finished, "착지 예측·착지 자세 유지·종료")
            try check(physics.feet.y == (kind == .upward ? 300 : 0), "도약/하강 목적지")
        }

        var falling = HopPlayback(kind: .downward, alreadyAirborne: true)
        try check(falling.frameIndex == 1, "갑자기 떨어지면 공중 모션부터 표시")
        falling.observe(grounded: false, landingSoon: true)
        try check(falling.frameIndex == 2, "착지 예측")
        falling.observe(grounded: false, landingSoon: false)
        try check(falling.frameIndex == 1, "발판이 사라지면 공중 모션으로 복귀")
    }
}
