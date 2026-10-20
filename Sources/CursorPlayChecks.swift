import AppKit

@MainActor enum CursorPlayChecks {
    static func run(atlas: SpriteAtlas) throws {
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw AssetError.invalid("커서 잡기 검사: \(message)") }
        }
        let canvas = CGRect(x: 0, y: 0, width: 200, height: 72)
        for mirrored in [false, true] {
            let offset = atlas.cursorAttachment(rolling: false, frame: 4).offset(in: atlas.cursorJump[4], height: 60, mirrored: mirrored)
            let cursor = CGPoint(x: mirrored ? 300 : 700, y: 400)
            var play = CursorPlay(start: CGPoint(x: 500, y: 74), cursor: cursor,
                                  gripOffset: offset, ceiling: 820)
            try check(play.mirrored == mirrored && play.frameIndex == 0, "좌우 방향·준비 시작")
            play.advance(by: 0.12, grounded: true)
            try check(play.frameIndex == 1, "웅크리기")
            play.advance(by: 0.12, grounded: true)
            try check(play.phase == .flying && play.frameIndex == 2 && play.feet == play.start, "도약 시작 좌표")
            play.advance(by: play.flightDuration - 0.000001, grounded: false)
            try check(abs(play.feet.x + offset.x - cursor.x) < 0.002 &&
                      abs(play.feet.y + offset.y - cursor.y) < 0.002, "실제 커서와 앞발의 정확한 접점")
            play.advance(by: 0.000002, grounded: false)
            try check(play.phase == .holding && play.hasCursor && play.frameIndex == 4, "공중에서 잡기")
            try check(!play.interrupted(by: cursor, mouseButtons: 0), "정지한 커서 유지")
            try check(play.interrupted(by: CGPoint(x: cursor.x + 2, y: cursor.y), mouseButtons: 0), "움직이면 놓기")
            try check(play.interrupted(by: cursor, mouseButtons: 1), "클릭하면 놓기")
            play.advance(by: 0.35, grounded: false)
            try check(play.phase == .falling && play.usesPhysics && play.frameIndex == 5, "잡은 채 중력 하강")
            play.advance(by: 0.1, grounded: true)
            try check(play.phase == .landing && play.frameIndex == 6, "실제 발판에 착지")
            play.advance(by: 0.17, grounded: true)
            try check(play.frameIndex == 7, "착지 후 마지막 점프 프레임")
            play.advance(by: 0.16, grounded: true)
            try check(play.rolling && play.frameIndex == 0, "정지하면 구르기 시작")
            var frames = Set<Int>()
            for _ in 0..<223 {
                frames.insert(play.frameIndex)
                play.advance(by: 0.01, grounded: true)
            }
            try check(frames == Set(0..<8), "구르기 8프레임 모두 재생")
            play.advance(by: 0.02, grounded: true)
            try check(play.phase == .finished && !play.hasCursor && play.usesPhysics, "종료 후 착지 위치 유지")
            for i in 0..<8 {
                let sprite = atlas.cursorRoll[i]
                let anchor = atlas.cursorAttachment(rolling: true, frame: i).offset(in: sprite, height: 60, mirrored: mirrored)
                let rect = sprite.drawingRect(in: canvas, height: 60)
                try check(rect.contains(CGPoint(x: canvas.midX + anchor.x, y: 6 + anchor.y)), "구르는 동안 커서가 앞발 영역에 있음")
            }
        }
        var hides = 0, shows = 0
        let owner = HeldCursor(hide: { hides += 1; return true }, show: { shows += 1 })
        try check(owner.begin() && owner.begin() && hides == 1, "중복 숨김 방지")
        owner.release(); owner.release()
        try check(shows == 1 && !owner.hidden, "모든 취소 경로에서 한 번만 표시 복구")
        let rejected = HeldCursor(hide: { false }, show: { shows += 1 })
        try check(!rejected.begin(), "숨기기 실패 처리")
        rejected.release()
        try check(shows == 1, "실패했을 때 표시 횟수 변경 안 함")
    }
}
