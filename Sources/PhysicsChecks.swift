import Foundation

enum PhysicsChecks {
    static func run() throws {
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw AssetError.invalid("물리 검사: \(message)") }
        }
        let area = CGRect(x: -1000, y: 30, width: 1200, height: 900)
        let lower = Ledge(id: 3, edge: .lower, minX: -650, maxX: -100, y: 180,
                          carrierOrigin: CGPoint(x: -650, y: 180))
        let upper = Ledge(id: 2, edge: .upper, minX: -650, maxX: -100, y: 550,
                          carrierOrigin: lower.carrierOrigin)
        func simulate(_ world: inout PetPhysics, seconds: Double) {
            for _ in 0..<Int(seconds * 120) { world.advance(by: 1.0 / 120) }
        }

        var world = PetPhysics(feet: CGPoint(x: -400, y: 700), area: area, bodyHeight: 120)
        world.updateLedges([lower, upper])
        simulate(&world, seconds: 2)
        try check(world.supportID == upper.id && world.feet.y == upper.y, "중력으로 가장 높은 발판에 착지")
        world.dropDown()
        simulate(&world, seconds: 2)
        try check(world.supportID == lower.id && world.feet.y == lower.y, "윗면에서 아랫면으로 내려가기")
        world.dropDown()
        simulate(&world, seconds: 2)
        try check(world.supportID == 0 && world.feet.y == area.minY, "아랫면에서 지면으로 내려가기")

        try check(world.jump(to: lower), "아랫면으로 점프 시작")
        var roseAboveLower = false
        for _ in 0..<240 {
            world.advance(by: 1.0 / 120)
            roseAboveLower = roseAboveLower || world.feet.y > lower.y + 10
        }
        try check(roseAboveLower && world.supportID == lower.id, "상승 시 통과·하강 시 착지")
        try check(world.jump(to: upper), "윗면으로 점프 시작")
        simulate(&world, seconds: 2)
        try check(world.supportID == upper.id, "높은 창 윗면으로 올라가기")

        var shiftedLower = lower, shiftedUpper = upper
        shiftedLower.minX += 30; shiftedLower.maxX += 30; shiftedLower.y += 25
        shiftedUpper.minX += 30; shiftedUpper.maxX += 30; shiftedUpper.y += 25
        shiftedLower.carrierOrigin.x += 30; shiftedLower.carrierOrigin.y += 25
        shiftedUpper.carrierOrigin = shiftedLower.carrierOrigin
        let previousFeet = world.feet
        world.updateLedges([shiftedLower, shiftedUpper])
        try check(world.feet == CGPoint(x: previousFeet.x + 30, y: previousFeet.y + 25),
                  "창 이동 시 강아지 함께 이동")
        world.updateLedges([])
        world.advance(by: 0.1)
        try check(!world.grounded && world.feet.y < shiftedUpper.y, "창이 닫히면 낙하")

        world.teleport(to: CGPoint(x: -400, y: upper.y))
        world.updateLedges([lower, upper])
        world.advance(by: 1.0 / 120)
        world.horizontalVelocity = 90
        simulate(&world, seconds: 6)
        try check(world.supportID == 0, "창 테두리 끝에서 지면으로 낙하")

        for direction in [-1.0, 1.0] {
            let edgeX = direction < 0 ? area.minX - 120 * 0.6 - 1 : area.maxX + 120 * 0.6 + 1
            var wrapping = PetPhysics(feet: CGPoint(x: edgeX, y: 200), area: area, bodyHeight: 120)
            wrapping.horizontalVelocity = direction * 90
            wrapping.advance(by: 1.0 / 120)
            try check(direction < 0 ? wrapping.feet.x > area.maxX : wrapping.feet.x < area.minX,
                      "좌우 화면 끝에서 반대편으로 연결")
            try check(abs(wrapping.feet.y - 200) < 1, "화면 연결 시 높이 유지")
            try check(wrapping.facesLeft == (direction < 0), "반대편 출현 후 방향 유지")
        }

        var slow = PetPhysics(feet: CGPoint(x: -400, y: 700), area: area, bodyHeight: 120)
        var fast = slow
        for _ in 0..<6 { slow.advance(by: 1.0 / 30) }
        for _ in 0..<12 { fast.advance(by: 1.0 / 60) }
        try check(abs(slow.feet.y - fast.feet.y) < 0.01, "프레임 간격에 독립적인 중력")
        world.teleport(to: CGPoint(x: -400, y: area.minY))
        world.advance(by: 1.0 / 120)
        world.jump(height: 10000)
        for _ in 0..<360 {
            world.advance(by: 1.0 / 120)
            try check(world.feet.y >= area.minY && world.feet.y <= world.ceiling + 0.01,
                      "지면·화면 위쪽 경계 유지")
        }

        let scene = CGRect(x: 0, y: 0, width: 1200, height: 1000)
        let front = DesktopWindow(id: 10, frame: CGRect(x: 250, y: 150, width: 250, height: 300))
        let back = DesktopWindow(id: 20, frame: CGRect(x: 100, y: 100, width: 700, height: 200))
        let ledges = WindowLedges.make(from: [front, back], area: scene)
        let visibleBackTop = ledges.filter { $0.id == 40 }
        try check(visibleBackTop.count == 2 &&
                  visibleBackTop.contains { $0.minX == 100 && $0.maxX == 250 } &&
                  visibleBackTop.contains { $0.minX == 500 && $0.maxX == 800 },
                  "앞 창에 가려진 테두리 제외")
        try check(ledges.contains { $0.id == 41 && $0.y == 100 }, "아랫면 감지")
        try check(WindowLedges.appKitFrame(CGRect(x: -600, y: 200, width: 400, height: 300),
                                            primaryHeight: 1000) ==
                  CGRect(x: -600, y: 500, width: 400, height: 300), "화면 좌표계 변환")
    }
}
