import Foundation

enum ClimbChecks {
    static func run() throws {
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw AssetError.invalid("창 오르기 검사: \(message)") }
        }
        let area = CGRect(x: 0, y: 0, width: 1400, height: 1000)
        let low = DesktopWindow(id: 10, frame: CGRect(x: 400, y: 120, width: 360, height: 180))
        let high = DesktopWindow(id: 20, frame: CGRect(x: 300, y: 320, width: 650, height: 280))
        var world = PetPhysics(feet: CGPoint(x: 500, y: 0), area: area, bodyHeight: 60)
        world.updateLedges(WindowLedges.make(from: [high, low], area: area))
        world.advance(by: 1.0 / 120)

        func land(_ world: inout PetPhysics, on target: Ledge) throws {
            try check(world.jump(to: target), "계획한 발판으로 점프 가능")
            for _ in 0..<600 {
                world.advance(by: 1.0 / 120)
                if world.grounded { break }
            }
            try check(world.supportID == target.id, "다른 높은 테두리를 건너뛰고 계획한 낮은 발판에 착지")
            world.horizontalVelocity = 0
        }

        var visited: [UInt64] = []
        for _ in 0..<8 {
            switch ClimbPlanner.nextStep(for: world) {
            case .jump(let target):
                visited.append(target.id)
                try land(&world, on: target)
            case .approach:
                throw AssetError.invalid("창 오르기 검사: 가까운 발판에 불필요한 접근")
            case .finished: break
            }
        }
        try check(visited == [21, 20, 41, 40], "낮은 창 아랫면 → 윗면 → 높은 창 아랫면 → 윗면")
        try check(world.feet.y == 600 && world.supportID == 40, "가장 높은 창에 도착")

        let highest = DesktopWindow(id: 30, frame: CGRect(x: 350, y: 680, width: 650, height: 120))
        world.updateLedges(WindowLedges.make(from: [highest, high, low], area: area))
        for expectedID in [UInt64(61), UInt64(60)] {
            guard case .jump(let target) = ClimbPlanner.nextStep(for: world) else {
                throw AssetError.invalid("창 오르기 검사: 세 번째 창으로 경로 연장")
            }
            try check(target.id == expectedID, "세 번째 창도 순서대로 오름")
            try land(&world, on: target)
        }
        guard case .finished = ClimbPlanner.nextStep(for: world) else {
            throw AssetError.invalid("창 오르기 검사: 최상단에서 오르기 종료")
        }

        // A much farther low window must still precede a high window right above the dog.
        let farLow = DesktopWindow(id: 10, frame: CGRect(x: 950, y: 100, width: 250, height: 200))
        let nearHigh = DesktopWindow(id: 20, frame: CGRect(x: 100, y: 200, width: 300, height: 500))
        var approaching = PetPhysics(feet: CGPoint(x: 200, y: 0), area: area, bodyHeight: 60)
        approaching.updateLedges(WindowLedges.make(from: [nearHigh, farLow], area: area))
        approaching.advance(by: 1.0 / 120)
        guard case .approach(let destinationX) = ClimbPlanner.nextStep(for: approaching) else {
            throw AssetError.invalid("창 오르기 검사: 먼 낮은 창으로 먼저 접근")
        }
        try check(destinationX > farLow.frame.minX, "높은 창으로 바로 점프하지 않음")
        var firstJump: Ledge?
        for _ in 0..<1200 {
            switch ClimbPlanner.nextStep(for: approaching) {
            case .jump(let target): firstJump = target
            case .approach(let x):
                approaching.horizontalVelocity = x < approaching.feet.x ? -90 : 90
                approaching.advance(by: 1.0 / 60)
            case .finished: break
            }
            if firstJump != nil { break }
        }
        try check(firstJump?.id == 21, "낮은 창 가까이 걸어간 후 첫 발판으로 점프")

        var completed: Set<UInt64> = []
        var reachedTops: [UInt64] = []
        for _ in 0..<2400 {
            switch ClimbPlanner.nextStep(for: approaching, completedWindows: completed) {
            case .jump(let target):
                if approaching.grounded {
                    try land(&approaching, on: target)
                    if target.edge == .upper {
                        completed.insert(target.id / 2)
                        reachedTops.append(target.id / 2)
                    }
                }
            case .approach(let x):
                approaching.horizontalVelocity = x < approaching.feet.x ? -90 : 90
                approaching.advance(by: 1.0 / 60)
            case .finished: break
            }
            if !approaching.grounded { approaching.advance(by: 1.0 / 60) }
            if completed.contains(20) { break }
        }
        try check(reachedTops == [10, 20], "큰 가로 간격에서도 낮은 창을 반복하지 않고 높은 창까지 도착")

        approaching.teleport(to: CGPoint(x: 200, y: 0))
        approaching.updateLedges(WindowLedges.make(from: [nearHigh], area: area))
        approaching.advance(by: 1.0 / 120)
        guard case .jump(let newTarget) = ClimbPlanner.nextStep(for: approaching) else {
            throw AssetError.invalid("창 오르기 검사: 창 닫힘 후 경로 갱신")
        }
        try check(newTarget.id == 41, "사라진 창을 기다리지 않고 남은 창부터 오름")
    }
}
