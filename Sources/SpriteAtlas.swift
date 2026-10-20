import AppKit
import ImageIO

struct DogSprite {
    let image: NSImage
    let headCenterX: CGFloat
    let pixelSize: CGSize
    var referenceHeight: CGFloat? = nil

    func drawingRect(in canvas: CGRect, height: CGFloat) -> CGRect {
        let scale = height / (referenceHeight ?? pixelSize.height)
        return CGRect(x: canvas.midX - headCenterX * scale,
                      y: canvas.minY + 6,
                      width: pixelSize.width * scale, height: pixelSize.height * scale)
    }

    func draw(in canvas: CGRect, height: CGFloat, mirrored: Bool = false) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .none
        if mirrored {
            let transform = NSAffineTransform()
            transform.translateX(by: canvas.midX * 2, yBy: 0)
            transform.scaleX(by: -1, yBy: 1)
            transform.concat()
        }
        image.draw(in: drawingRect(in: canvas, height: height),
                   from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }
}

struct SpriteAtlas {
    let character: PetCharacter
    let resting: DogSprite
    let idle: [DogSprite]
    let walking: [DogSprite]
    let walkingLeft: [DogSprite]?
    let running: [DogSprite]
    let jumping: [DogSprite]
    let descending: [DogSprite]
    let gazing: [DogSprite]
    let cursorJump: [DogSprite]
    let cursorRoll: [DogSprite]
    let leaping: [DogSprite]
    private var customGrips: [String: [CharacterGrip]]? = nil

    init(directory: URL, character: PetCharacter = .puppy) throws {
        self.character = character
        if character == .bonobono {
            let folder = directory.appendingPathComponent("bonobono-sprites")
            resting = try Self.frames(folder.appendingPathComponent("01-standing.png"), columns: 1, rows: 1, anchorFeet: true)[0]
            idle = try Self.scaledTogether(Self.frames(folder.appendingPathComponent("06-idle.png"), anchorFeet: true))
            gazing = try Self.scaledTogether(Self.frames(folder.appendingPathComponent("02-look-up.png"), columns: 3, rows: 1, anchorFeet: true))
            let right = try Self.subjectFrames(folder.appendingPathComponent("04-walk-right.png"))
            let left = try Self.subjectFrames(folder.appendingPathComponent("05-walk-left.png"))
            let walks = Self.scaledTogether(right + left)
            walking = Array(walks.prefix(8))
            walkingLeft = Array(walks.suffix(8))
            running = try Self.scaledTogether(Self.subjectFrames(folder.appendingPathComponent("03-run-right.png")))
            let leap = try Self.scaledTogether(Self.subjectFrames(folder.appendingPathComponent("07-leap.png")))
            leaping = leap
            jumping = [0, 2, 5, 6].map { leap[$0] }
            descending = [3, 4, 5, 6].map { leap[$0] }
            let catchSheet = try Self.subjectFrames(folder.appendingPathComponent("09-jump-no-cursor.png"))
            let rollSheet = try Self.subjectFrames(folder.appendingPathComponent("11-roll-no-cursor.png"))
            let cursorFrames = Self.scaledTogether(catchSheet + rollSheet)
            cursorJump = Array(cursorFrames.prefix(8))
            cursorRoll = Array(cursorFrames.suffix(8))
            return
        }
        walkingLeft = nil
        leaping = []
        idle = try Self.frames(directory.appendingPathComponent("유휴상태.png"))
        resting = idle[0]
        walking = try Self.frames(directory.appendingPathComponent("오른쪽으로 걷는 상태.png"), centerWholeSprite: true)
        let runSheet = try Self.subjectFrames(directory.appendingPathComponent("오른쪽 뛰는 상태.png"))
        let runHeight = runSheet.map(\.pixelSize.height).max()!
        running = runSheet.map { original in
            var sprite = original
            sprite.referenceHeight = runHeight
            return sprite
        }
        let hopSheet = try Self.subjectFrames(directory.appendingPathComponent("픽셀 강아지의 힘찬 도약 스프라이트 시트.png"))
        // Keep one scale across all eight poses so crouching and stretching remain visible.
        let referenceHeight = hopSheet.map(\.pixelSize.height).max()!
        let hopFrames = hopSheet.map { original -> DogSprite in
            var sprite = original
            sprite.referenceHeight = referenceHeight
            return sprite
        }
        jumping = Array(hopFrames.prefix(4))
        descending = Array(hopFrames.suffix(4))
        let gazeSheet = try Self.frames(directory.appendingPathComponent("세 방향으로 올려보는 픽셀 강아지.png"),
                                        columns: 3, rows: 1, anchorFeet: true)
        let gazeHeight = gazeSheet.map(\.pixelSize.height).max()!
        gazing = gazeSheet.map { original in
            var sprite = original
            sprite.referenceHeight = gazeHeight
            return sprite
        }
        let catchSheet = try Self.subjectFrames(directory.appendingPathComponent("puppy-jump-8frames-no-cursor.png"))
        let rollSheet = try Self.subjectFrames(directory.appendingPathComponent("puppy-roll-8frames-no-cursor.png"))
        let cursorHeight = (catchSheet + rollSheet).map(\.pixelSize.height).max()!
        func scaled(_ sprites: [DogSprite]) -> [DogSprite] {
            sprites.map { original in
                var sprite = original
                sprite.referenceHeight = cursorHeight
                return sprite
            }
        }
        cursorJump = scaled(catchSheet)
        cursorRoll = scaled(rollSheet)
    }

    init(custom profile: CustomCharacter) throws {
        try profile.validate()
        guard let directory = profile.directory else { throw AssetError.invalid("캐릭터 이미지 폴더가 없습니다.") }
        character = profile.base
        func load(_ slot: CharacterSlot) throws -> [DogSprite] {
            guard let name = profile.assets[slot.rawValue] else { throw AssetError.invalid("\(slot.title) 이미지가 없습니다.") }
            return try Self.customFrames(directory.appendingPathComponent(name), slot: slot)
        }
        resting = try load(.standing)[0]
        idle = try Self.scaledTogether(load(.idle))
        gazing = try Self.scaledTogether(load(.gaze))
        walking = try Self.scaledTogether(load(.walk))
        walkingLeft = try profile.assets[CharacterSlot.walkLeft.rawValue] == nil ? nil : Self.scaledTogether(load(.walkLeft))
        running = try Self.scaledTogether(load(.run))
        let jump = try Self.scaledTogether(load(.leap))
        if profile.leapLayout == "continuous" {
            leaping = jump
            jumping = [0, 2, 5, 6].map { jump[$0] }
            descending = [3, 4, 5, 6].map { jump[$0] }
        } else {
            leaping = []
            jumping = Array(jump.prefix(4))
            descending = Array(jump.suffix(4))
        }
        let cursor = try Self.scaledTogether(load(.cursorJump) + load(.cursorRoll))
        cursorJump = Array(cursor.prefix(8))
        cursorRoll = Array(cursor.suffix(8))
        customGrips = profile.grips
    }

    static func customFrames(_ url: URL, slot: CharacterSlot) throws -> [DogSprite] {
        try frames(url, columns: slot.columns, rows: slot.rows,
                   centerWholeSprite: slot != .standing && slot != .gaze && slot != .idle,
                   anchorFeet: slot == .standing || slot == .gaze || slot == .idle)
    }

    static func hasTransparentBackground(_ url: URL) throws -> Bool {
        let image = try load(url)
        let pixels = try rgbaPixels(image)
        return stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] < 24 }
    }

    private static func scaledTogether(_ sprites: [DogSprite]) -> [DogSprite] {
        let height = sprites.map(\.pixelSize.height).max()!
        return sprites.map { original in
            var sprite = original
            sprite.referenceHeight = height
            return sprite
        }
    }

    var allSprites: [DogSprite] {
        // Avoid a long overloaded '+' chain, which exceeds the type-checking
        // budget in some Swift toolchains used by the release runners.
        let animations: [[DogSprite]] = [idle, walking, walkingLeft ?? [], running,
                                        jumping, descending, gazing, cursorJump, cursorRoll, leaping]
        var result: [DogSprite] = [resting]
        for frames in animations { result.append(contentsOf: frames) }
        return result
    }

    func movementSprite(gait: GroundGait, facingLeft: Bool, at time: TimeInterval) -> (DogSprite, Bool) {
        let index = gait.frameIndex(at: time)
        if gait == .walking, facingLeft, let walkingLeft { return (walkingLeft[index], false) }
        return ((gait == .running ? running : walking)[index], facingLeft)
    }

    func hopSprite(for playback: HopPlayback, verticalVelocity: CGFloat) -> DogSprite {
        guard !leaping.isEmpty else {
            return (playback.kind == .upward ? jumping : descending)[playback.frameIndex]
        }
        let index: Int
        switch playback.phase {
        case .preparing: index = 0
        case .airborne:
            if playback.kind == .upward && playback.phaseTime < 0.09 { index = 1 }
            else if verticalVelocity > 90 { index = 2 }
            else if verticalVelocity >= -90 { index = 3 }
            else { index = 4 }
        case .beforeLanding: index = 5
        case .landing: index = playback.phaseTime < 0.12 ? 6 : 7
        }
        return leaping[index]
    }

    func cursorAttachment(rolling: Bool, frame: Int) -> CursorAttachment {
        var attachment: CursorAttachment = rolling ? .roll(frame, character: character) : .jump(frame, character: character)
        if let point = customGrips?[rolling ? "roll" : "jump"]?[frame] {
            attachment = CursorAttachment(point: CGPoint(x: point.x, y: point.y), angle: attachment.angle)
        }
        return attachment
    }

    var windowWidthRatio: CGFloat {
        allSprites.reduce(1.25) { ratio, sprite in
            let extent = max(sprite.headCenterX, sprite.pixelSize.width - sprite.headCenterX)
            return max(ratio, 2 * extent / (sprite.referenceHeight ?? sprite.pixelSize.height))
        }
    }

    private static func subjectFrames(_ url: URL) throws -> [DogSprite] {
        let image = try Self.load(url)
        let width = image.width, height = image.height
        let pixels = try Self.rgbaPixels(image)
        var visited = [Bool](repeating: false, count: width * height)
        var bounds: [CGRect] = []
        // Some poses extend past the nominal tile boundary. Locate the eight connected
        // silhouettes in the original sheet instead of clipping feet or copying a neighbor.
        for seed in 0..<(width * height) where !visited[seed] && pixels[seed * 4 + 3] > 24 {
            var queue = [seed], head = 0
            var left = seed % width, right = left, top = seed / width, bottom = top
            visited[seed] = true
            while head < queue.count {
                let index = queue[head]
                head += 1
                let x = index % width, y = index / width
                left = min(left, x); right = max(right, x)
                top = min(top, y); bottom = max(bottom, y)
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let next = ny * width + nx
                        if !visited[next], pixels[next * 4 + 3] > 24 {
                            visited[next] = true
                            queue.append(next)
                        }
                    }
                }
            }
            if queue.count > max(1000, width * height / 1000) {
                bounds.append(CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1))
            }
        }
        func slot(_ rect: CGRect) -> Int {
            min(1, Int(rect.midY * 2 / CGFloat(height))) * 4 +
                min(3, Int(rect.midX * 4 / CGFloat(width)))
        }
        guard bounds.count == 8, Set(bounds.map(slot)).count == 8 else {
            throw AssetError.invalid("\(url.lastPathComponent)에서 4칸 × 2줄의 캐릭터 8개를 분리할 수 없습니다.")
        }
        return try bounds.sorted { slot($0) < slot($1) }.map { rect in
            guard let subject = image.cropping(to: rect) else {
                throw AssetError.invalid("\(url.lastPathComponent)의 자세를 자를 수 없습니다.")
            }
            return try Self.sprite(subject, centerWholeSprite: true)
        }
    }

    private static func frames(_ url: URL, columns: Int = 4, rows: Int = 2,
                               centerWholeSprite: Bool = false, anchorFeet: Bool = false) throws -> [DogSprite] {
        let sheet = try Self.load(url)
        // Integer boundaries cover every pixel even when the sheet is 1774 × 887.
        return try (0..<(columns * rows)).map { index in
            let column = index % columns, row = index / columns
            let x = column * sheet.width / columns, y = row * sheet.height / rows
            let right = (column + 1) * sheet.width / columns
            let bottom = (row + 1) * sheet.height / rows
            guard let tile = sheet.cropping(to: CGRect(x: x, y: y,
                                                      width: right - x, height: bottom - y)) else {
                throw AssetError.invalid("\(url.lastPathComponent)의 프레임 \(index + 1)을 자를 수 없습니다.")
            }
            return try Self.sprite(tile, centerWholeSprite: centerWholeSprite, anchorFeet: anchorFeet)
        }
    }

    private static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AssetError.invalid("이미지를 열 수 없습니다: \(url.lastPathComponent)")
        }
        return image
    }

    private static func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                            CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw AssetError.invalid("이미지 픽셀을 읽을 수 없습니다.") }
        return pixels
    }

    private static func sprite(_ image: CGImage, centerWholeSprite: Bool, anchorFeet: Bool = false) throws -> DogSprite {
        let width = image.width, height = image.height
        let pixels = try Self.rgbaPixels(image)
        var left = width, top = height, right = -1, bottom = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 24 {
                left = min(left, x); right = max(right, x)
                top = min(top, y); bottom = max(bottom, y)
            }
        }
        guard right >= left, bottom >= top else {
            throw AssetError.invalid("이미지에 캐릭터가 없습니다.")
        }
        // Anchor by the head rather than the tail: wagging must not move the body.
        var headLeft = width, headRight = -1
        let headBottom = top + Int(Double(bottom - top + 1) * 0.55)
        for y in top..<headBottom {
            for x in left...right where pixels[(y * width + x) * 4 + 3] > 24 {
                headLeft = min(headLeft, x); headRight = max(headRight, x)
            }
        }
        let bounds = CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        guard let trimmed = image.cropping(to: bounds) else {
            throw AssetError.invalid("투명 여백을 자를 수 없습니다.")
        }
        let size = bounds.size
        var anchorX = centerWholeSprite ? size.width / 2 : CGFloat(headLeft + headRight) / 2 - CGFloat(left)
        if anchorFeet {
            // The three heads tilt independently; register by the paws so the body stays put.
            var footLeft = width, footRight = -1
            let footTop = bottom - Int(size.height * 0.15)
            for y in footTop...bottom {
                for x in left...right where pixels[(y * width + x) * 4 + 3] > 24 {
                    footLeft = min(footLeft, x); footRight = max(footRight, x)
                }
            }
            if footRight >= footLeft { anchorX = CGFloat(footLeft + footRight) / 2 - CGFloat(left) }
        }
        return DogSprite(image: NSImage(cgImage: trimmed, size: size),
                         headCenterX: anchorX,
                         pixelSize: size)
    }
}

enum AssetError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}
