import AppKit

@MainActor enum CustomCharacterChecks {
    static func run(imagesRoot: URL, onCreated: (CustomCharacter, SpriteAtlas) throws -> Void) throws {
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw AssetError.invalid("캐릭터 생성 검사: \(message)") }
        }
        func rejects(_ message: String, _ operation: () throws -> Void) throws {
            var rejected = false
            do { try operation() } catch { rejected = true }
            try check(rejected, message)
        }
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("character-check-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let store = CustomCharacterStore(root: temporary.appendingPathComponent("characters"))
        let puppyExamples = try CustomCharacterStore.exportExamples(template: .puppy, imagesRoot: imagesRoot, parent: temporary)
        try check(!fm.fileExists(atPath: puppyExamples.appendingPathComponent(CharacterSlot.walkLeft.filename).path), "왼쪽 전용 걷기가 없는 강아지 예시는 자동 반전 사용")
        for slot in CharacterSlot.allCases where slot.required {
            try CustomCharacterStore.validatePNG(puppyExamples.appendingPathComponent(slot.filename), slot: slot)
        }
        let examples = try CustomCharacterStore.exportExamples(template: .bonobono, imagesRoot: imagesRoot, parent: temporary)
        try check(try fm.contentsOfDirectory(at: examples, includingPropertiesForKeys: nil).count == 12, "예시 9종·참고용 2장·만드는 방법 저장")
        let creator = CharacterCreator(store: store, imagesRoot: imagesRoot, template: .bonobono)
        defer { creator.close() }
        try check(!creator.saveButton.isEnabled && !creator.nameField.stringValue.isEmpty, "이름 추천·필수 이미지 입력 전 저장 제한")
        for slot in CharacterSlot.allCases where slot.required {
            try creator.assign(examples.appendingPathComponent(slot.filename), to: slot)
        }
        try check(creator.saveButton.isEnabled, "필수 8종 입력 후 저장 가능")
        creator.nameField.stringValue = "  나의 친구  "
        creator.updateStatus()
        let viewer = CharacterAnimationPreview(title: "손 위치 검사", frames: try SpriteAtlas.customFrames(creator.files[.cursorJump]!, slot: .cursorJump), grips: creator.grips["jump"])
        viewer.onGrip = { index, point in creator.grips["jump"]?[index] = point }
        viewer.chooseFrame(4)
        viewer.placeGrip(CharacterGrip(x: 0.61, y: 0.52))
        viewer.close()
        try check(creator.grips["jump"]?[4].x == 0.61, "미리보기에서 고른 프레임 손 위치 반영")
        creator.showWindow(nil)
        creator.window?.displayIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        creator.window?.contentView?.layoutSubtreeIfNeeded()
        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.compactMap { scrollView(in: $0) }.first
        }
        let content = creator.window!.contentView!
        if let scroll = scrollView(in: content) {
            try check(scroll.frame.height > 100 && (scroll.documentView?.frame.height ?? 0) > scroll.frame.height, "동작 목록 스크롤 배치")
        } else { try check(false, "동작 목록 없음") }
        var result: (CustomCharacter, SpriteAtlas)?
        creator.onCreated = { result = ($0, $1) }
        creator.save()
        guard let (profile, atlas) = result else { throw AssetError.invalid(creator.statusLabel.stringValue) }
        try check(profile.name == "나의 친구" && profile.directory?.lastPathComponent == profile.id, "이름 정리·독립 폴더 저장")
        try check(atlas.leaping.count == 8 && atlas.walkingLeft == nil && atlas.movementSprite(gait: .walking, facingLeft: true, at: 0).1, "연속 점프·왼쪽 걷기 자동 반전")
        try check(atlas.cursorAttachment(rolling: false, frame: 4).point == CGPoint(x: 0.61, y: 0.52), "사용자 손 위치 재생 적용")
        let reloaded = store.all()
        try check(reloaded.count == 1 && reloaded[0].id == profile.id, "저장한 캐릭터 재검색")
        let restored = try SpriteAtlas(custom: reloaded[0])
        try check(restored.cursorAttachment(rolling: false, frame: 4).point == CGPoint(x: 0.61, y: 0.52), "저장된 손 위치 복원")
        var split = profile; split.leapLayout = "split"
        let splitAtlas = try SpriteAtlas(custom: split)
        try check(splitAtlas.leaping.isEmpty && splitAtlas.jumping.count == 4 && splitAtlas.descending.count == 4, "두 줄 도약·하강 순서")
        for slot in CharacterSlot.allCases where slot.required {
            try check(try Data(contentsOf: examples.appendingPathComponent(slot.filename)) == Data(contentsOf: profile.directory!.appendingPathComponent(slot.filename)), "원본 PNG 보존")
        }
        try rejects("같은 이름 거부") { _ = try store.create(name: "나의 친구", template: .bonobono, leapLayout: "continuous", files: creator.files, grips: creator.grips) }
        try rejects("필수 이미지 누락 거부") { _ = try store.create(name: "누락", template: .puppy, leapLayout: "split", files: [:], grips: creator.grips) }
        try rejects("빈 이름 거부") { _ = try store.create(name: " ", template: .puppy, leapLayout: "split", files: [:], grips: creator.grips) }
        let invalid = temporary.appendingPathComponent("invalid.png")
        try Data("not a png".utf8).write(to: invalid)
        try rejects("PNG 위장 파일 거부") { try CustomCharacterStore.validatePNG(invalid, slot: .standing) }
        for opaque in [false, true] {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let color = NSColor(deviceRed: opaque ? 1 : 0, green: opaque ? 1 : 0, blue: opaque ? 1 : 0, alpha: opaque ? 1 : 0)
            for y in 0..<32 { for x in 0..<64 { bitmap.setColor(color, atX: x, y: y) } }
            try bitmap.representation(using: .png, properties: [:])!.write(to: invalid)
            try rejects(opaque ? "불투명 배경 거부" : "빈 프레임 거부") { try CustomCharacterStore.validatePNG(invalid, slot: .run) }
        }
        try check(!((try? fm.contentsOfDirectory(atPath: store.root.path)) ?? []).contains { $0.hasPrefix(".pending-") }, "임시 저장 파일 정리")
        try onCreated(profile, atlas)
        print("PASS: 캐릭터 생성 UI·예시 저장·필수 PNG 검사·이름·독립 저장·재실행 복원·커서 손 위치·메뉴 적용")
    }
}
