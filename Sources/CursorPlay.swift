import AppKit
import Darwin

/// The real pointer stays at its original hotspot. Only its picture travels with the dog.
/// Consequently mouse movement can always interrupt the trick without a cursor warp.
struct CursorPlay {
    enum Phase { case preparing, flying, holding, falling, landing, rolling, finished }
    private(set) var phase = Phase.preparing
    private(set) var elapsed: TimeInterval = 0
    let originalCursor: CGPoint
    let start: CGPoint
    let destination: CGPoint
    let mirrored: Bool
    let flightDuration: TimeInterval
    let launchVelocity: CGFloat

    init(start: CGPoint, cursor: CGPoint, gripOffset: CGPoint, ceiling: CGFloat) {
        self.start = start
        originalCursor = cursor
        mirrored = cursor.x < start.x
        destination = CGPoint(x: cursor.x - gripOffset.x, y: cursor.y - gripOffset.y)
        let rise = destination.y - start.y
        let apex = min(ceiling - start.y, max(45, rise))
        launchVelocity = sqrt(2 * PetPhysics.gravity * max(0, apex))
        // Catch at the apex or on the descending side of a short jump.
        flightDuration = Double((launchVelocity + sqrt(max(0, launchVelocity * launchVelocity - 2 * PetPhysics.gravity * rise))) / PetPhysics.gravity)
    }

    var hasCursor: Bool {
        phase == .holding || phase == .falling || phase == .landing || phase == .rolling
    }
    var usesPhysics: Bool { phase == .falling || phase == .landing || phase == .rolling || phase == .finished }
    var rolling: Bool { phase == .rolling }
    var frameIndex: Int {
        switch phase {
        case .preparing: return elapsed < 0.1 ? 0 : 1
        case .flying: return elapsed < flightDuration * 0.5 ? 2 : 3
        case .holding: return 4
        case .falling: return 5
        case .landing: return elapsed < 0.16 ? 6 : 7
        case .rolling: return min(15, Int(elapsed / 0.14)) % 8
        case .finished: return 7
        }
    }
    var feet: CGPoint {
        guard phase != .preparing else { return start }
        guard phase == .flying else { return destination }
        let time = CGFloat(min(elapsed, flightDuration))
        let progress = flightDuration > 0 ? time / CGFloat(flightDuration) : 1
        return CGPoint(x: start.x + (destination.x - start.x) * progress,
                       y: start.y + launchVelocity * time - PetPhysics.gravity * time * time / 2)
    }
    func interrupted(by cursor: CGPoint, mouseButtons: Int) -> Bool {
        mouseButtons != 0 || hypot(cursor.x - originalCursor.x, cursor.y - originalCursor.y) > 1
    }
    mutating func advance(by delta: TimeInterval, grounded: Bool) {
        elapsed += max(0, delta)
        switch phase {
        case .preparing where elapsed >= 0.24: transition(to: .flying)
        case .flying where elapsed >= flightDuration: transition(to: .holding)
        case .holding where elapsed >= 0.35: transition(to: .falling)
        case .falling where grounded: transition(to: .landing)
        case .landing where !grounded: transition(to: .falling)
        case .landing where elapsed >= 0.32: transition(to: .rolling)
        case .rolling where !grounded: transition(to: .falling)
        case .rolling where elapsed >= 2.24: transition(to: .finished)
        default: break
        }
    }
    private mutating func transition(to phase: Phase) { self.phase = phase; elapsed = 0 }
}

struct CursorAttachment: Equatable {
    let point: CGPoint // Normalized in the trimmed sprite, Y increases upward.
    let angle: CGFloat
    static func jump(_ frame: Int, character: PetCharacter = .puppy) -> CursorAttachment {
        if character == .bonobono {
            let points: [CGPoint] = [.zero, .zero, .zero, .zero,
                CGPoint(x: 0.84, y: 0.64), CGPoint(x: 0.79, y: 0.39),
                CGPoint(x: 0.76, y: 0.25), CGPoint(x: 0.72, y: 0.33)]
            return CursorAttachment(point: points[frame], angle: -25)
        }
        let points: [CGPoint] = [.zero, .zero, .zero, .zero,
            CGPoint(x: 0.80, y: 0.49), CGPoint(x: 0.80, y: 0.40),
            CGPoint(x: 0.79, y: 0.23), CGPoint(x: 0.74, y: 0.37)]
        return CursorAttachment(point: points[frame], angle: -25)
    }
    static func roll(_ frame: Int, character: PetCharacter = .puppy) -> CursorAttachment {
        if character == .bonobono {
            let points = [CGPoint(x: 0.72, y: 0.15), CGPoint(x: 0.75, y: 0.17),
                CGPoint(x: 0.59, y: 0.40), CGPoint(x: 0.34, y: 0.40),
                CGPoint(x: 0.34, y: 0.47), CGPoint(x: 0.37, y: 0.25),
                CGPoint(x: 0.31, y: 0.16), CGPoint(x: 0.23, y: 0.16)]
            return CursorAttachment(point: points[frame], angle: CGFloat([-25, -50, -95, -145, -195, -245, -285, -315][frame]))
        }
        let points = [CGPoint(x: 0.80, y: 0.23), CGPoint(x: 0.61, y: 0.20),
            CGPoint(x: 0.67, y: 0.51), CGPoint(x: 0.50, y: 0.39),
            CGPoint(x: 0.42, y: 0.48), CGPoint(x: 0.56, y: 0.28),
            CGPoint(x: 0.76, y: 0.23), CGPoint(x: 0.76, y: 0.25)]
        return CursorAttachment(point: points[frame], angle: CGFloat([-25, -65, -110, -155, -210, -290, -360, -385][frame]))
    }
    func offset(in sprite: DogSprite, height: CGFloat, mirrored: Bool) -> CGPoint {
        let scale = height / (sprite.referenceHeight ?? sprite.pixelSize.height)
        let x = (point.x * sprite.pixelSize.width - sprite.headCenterX) * scale
        return CGPoint(x: mirrored ? -x : x, y: point.y * sprite.pixelSize.height * scale)
    }
    @MainActor func draw(in canvas: CGRect, sprite: DogSprite, height: CGFloat, mirrored: Bool) {
        let offset = offset(in: sprite, height: height, mirrored: mirrored)
        let cursor = NSCursor.arrow.image
        let cursorHeight = max(14, height * 0.32)
        let size = CGSize(width: cursorHeight * cursor.size.width / cursor.size.height, height: cursorHeight)
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: canvas.midX + offset.x, yBy: canvas.minY + 6 + offset.y)
        transform.rotate(byDegrees: mirrored ? -angle : angle)
        if mirrored { transform.scaleX(by: -1, yBy: 1) }
        transform.concat()
        cursor.draw(in: CGRect(x: -size.width / 2, y: -size.height * 0.38, width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Own exactly one hide/show pair, including every cancellation and termination path.
@MainActor final class HeldCursor {
    private(set) var hidden = false
    private let hide: @MainActor () -> Bool
    private let show: @MainActor () -> Void
    init(hide: @escaping @MainActor () -> Bool = { SystemCursorVisibility.hide() },
         show: @escaping @MainActor () -> Void = { _ = CGDisplayShowCursor(CGMainDisplayID()) }) {
        self.hide = hide; self.show = show
    }
    func begin() -> Bool {
        if hidden { return true }
        hidden = hide()
        return hidden
    }
    func release() {
        guard hidden else { return }
        hidden = false
        show()
    }
}

@MainActor enum SystemCursorVisibility {
    // Quartz normally only changes the foreground app's cursor. Configure this connection
    // to own its hide/show pair in the background, without activating or stealing focus.
    // These optional WindowServer symbols are resolved at runtime, never force-linked.
    static let backgroundHidingAvailable: Bool = {
        guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return false }
        defer { dlclose(library) }
        guard let connectionSymbol = dlsym(library, "CGSMainConnectionID"),
              let propertySymbol = dlsym(library, "CGSSetConnectionProperty") else { return false }
        typealias Connection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let connection = unsafeBitCast(connectionSymbol, to: Connection.self)()
        let setProperty = unsafeBitCast(propertySymbol, to: SetProperty.self)
        return setProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0
    }()

    static func hide() -> Bool {
        // If a future OS removes background support, stop the trick rather than displaying
        // two cursors or bringing another app out of focus.
        guard backgroundHidingAvailable || NSApp.isActive else { return false }
        return CGDisplayHideCursor(CGMainDisplayID()) == .success
    }
}
