import Foundation

enum KeyboardChecks {
    static func run() throws {
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw AssetError.invalid("키보드 검사: \(message)") }
        }
        var input = KeyboardControls()
        input.keyDown(code: 0, isRepeat: false)
        try check(input.horizontalAxis == -1, "A 왼쪽 이동")
        input.keyDown(code: 2, isRepeat: false)
        try check(input.horizontalAxis == 0, "A+D 동시 입력 정지")
        input.keyUp(code: 0)
        try check(input.horizontalAxis == 1, "A를 놓으면 D 방향으로 이동")
        input.keyUp(code: 2)
        try check(input.horizontalAxis == 0, "키를 놓으면 정지")
        try check(input.keyDown(code: 49, isRepeat: false) == .jump, "스페이스 점프")
        try check(input.keyDown(code: 49, isRepeat: true) == nil, "길게 누른 점프 키 자동 반복 방지")
        input.keyUp(code: 49)
        try check(input.keyDown(code: 49, isRepeat: false) == .jump, "다시 누르면 새 점프")
        input.reset()
        try check(input.keyDown(code: 13, isRepeat: false) == .jump, "W 점프")
        try check(input.keyDown(code: 1, isRepeat: false) == .down, "S 하강")
        try check(input.keyDown(code: 53, isRepeat: false) == .exit, "Esc 자동 모드 복귀")
        input.reset()
        input.running = true
        input.keyDown(code: 2, isRepeat: false)
        var world = PetPhysics(feet: CGPoint(x: 400, y: 0), area: CGRect(x: 0, y: 0, width: 1200, height: 900),
                               bodyHeight: 60)
        world.horizontalVelocity = input.horizontalAxis * input.gait.speed
        for _ in 0..<60 { world.advance(by: 1.0 / 60) }
        try check(abs(world.feet.x - 580) < 0.01, "Shift+D 달리기 실제 이동")
        input.reset()
        world.horizontalVelocity = input.horizontalAxis * input.gait.speed
        let stopped = world.feet.x
        for _ in 0..<60 { world.advance(by: 1.0 / 60) }
        try check(world.feet.x == stopped && input.gait == .walking, "포커스 해제 후 키 상태·이동 초기화")
    }
}
