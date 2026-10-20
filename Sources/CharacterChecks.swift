import AppKit

@MainActor enum CharacterChecks {
    static func run(atlas: SpriteAtlas) throws {
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw AssetError.invalid("\(atlas.character.displayName) 검사: \(message)") }
        }
        try check(PetCharacter.restored(from: atlas.character.rawValue) == atlas.character, "저장된 선택 복원")
        try check(PetCharacter.restored(from: nil) == .puppy && PetCharacter.restored(from: "missing") == .puppy,
                  "이전 설정·알 수 없는 설정의 기본 캐릭터")
        try check(atlas.idle.count == 8 && atlas.walking.count == 8 && atlas.running.count == 8 &&
                  atlas.gazing.count == 3 && atlas.cursorJump.count == 8 && atlas.cursorRoll.count == 8,
                  "필수 동작 프레임")
        for scale in PetSizing.scales {
            let height = CGFloat(60 * scale)
            let canvas = CGRect(x: 0, y: 0, width: height * atlas.windowWidthRatio + 12, height: height + 12)
            for sprite in atlas.allSprites {
                try check(canvas.contains(sprite.drawingRect(in: canvas, height: height)), "전 동작·전 배율에서 이미지 잘림 없음")
            }
        }
        let leftWalk = atlas.movementSprite(gait: .walking, facingLeft: true, at: 0)
        let leftRun = atlas.movementSprite(gait: .running, facingLeft: true, at: 0)
        try check(leftRun.1 && leftRun.0.image === atlas.running[0].image, "왼쪽 달리기 좌우 반전")
        if atlas.character == .bonobono {
            try check(atlas.walkingLeft?.count == 8 && !leftWalk.1 && leftWalk.0.image === atlas.walkingLeft![0].image,
                      "전용 왼쪽 걷기 사용·중복 반전 없음")
            try check(atlas.leaping.count == 8, "연속 도약 8프레임")
            var hop = HopPlayback(kind: .upward)
            var seen: Set<ObjectIdentifier> = []
            func sample(_ velocity: CGFloat) {
                seen.insert(ObjectIdentifier(atlas.hopSprite(for: hop, verticalVelocity: velocity).image))
            }
            sample(0)
            hop.launched(); sample(300)
            hop.advanceClock(by: 0.1); sample(300); sample(0); sample(-200)
            hop.observe(grounded: false, landingSoon: true); sample(-200)
            hop.advanceClock(by: 0.05)
            hop.observe(grounded: true, landingSoon: true); sample(0)
            hop.advanceClock(by: 0.13); sample(0)
            try check(seen.count == 8, "도약 → 정점 → 하강 → 착지 → 회복 전체 자세")
        } else {
            try check(leftWalk.1 && leftWalk.0.image === atlas.walking[0].image, "기존 강아지 왼쪽 걷기 유지")
        }
    }
}
