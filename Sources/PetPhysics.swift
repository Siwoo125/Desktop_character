import Foundation

enum LedgeEdge: String { case ground, upper, lower }

struct Ledge: Equatable {
    let id: UInt64
    let edge: LedgeEdge
    var minX: CGFloat
    var maxX: CGFloat
    var y: CGFloat
    var carrierOrigin: CGPoint

    func supports(_ x: CGFloat, footHalfWidth: CGFloat) -> Bool {
        edge == .ground || (x + footHalfWidth > minX + 3 && x - footHalfWidth < maxX - 3)
    }
}

/// The position is the center of the paws, in AppKit screen points (Y increases upward).
/// Window rims are one-way platforms: pass upward through them and land while falling.
struct PetPhysics {
    static let gravity: CGFloat = 1300
    static let walkingSpeed: CGFloat = 90
    var area: CGRect
    var bodyHeight: CGFloat
    var wrapHalfWidth: CGFloat? = nil
    private(set) var feet: CGPoint
    private(set) var verticalVelocity: CGFloat = 0
    var horizontalVelocity: CGFloat = 0 {
        didSet { if abs(horizontalVelocity) > 0.1 { facesLeft = horizontalVelocity < 0 } }
    }
    private(set) var facesLeft = false
    private(set) var supportID: UInt64?
    private(set) var ledges: [Ledge] = []
    private var dropBelowY: CGFloat?
    private var intendedLandingID: UInt64?

    init(feet: CGPoint, area: CGRect, bodyHeight: CGFloat) {
        self.feet = feet
        self.area = area
        self.bodyHeight = bodyHeight
        updateLedges([])
    }

    var grounded: Bool { supportID != nil }
    var footHalfWidth: CGFloat { bodyHeight * 0.22 }
    var ceiling: CGFloat { max(area.minY, area.maxY - bodyHeight - 6) }
    var support: Ledge? {
        ledges.first { $0.id == supportID && $0.supports(feet.x, footHalfWidth: footHalfWidth) }
    }
    var moving: Bool { !grounded || abs(horizontalVelocity) > 0.1 }

    func willLandSoon(within duration: TimeInterval = 0.15) -> Bool {
        guard !grounded, verticalVelocity <= 0 else { return false }
        var probe = self
        var remaining = duration
        while remaining > 0 {
            let delta = min(remaining, 1.0 / 60)
            probe.advance(by: delta)
            if probe.grounded { return true }
            remaining -= delta
        }
        return false
    }

    mutating func teleport(to point: CGPoint) {
        feet = CGPoint(x: point.x, y: min(ceiling, max(area.minY, point.y)))
        verticalVelocity = 0
        horizontalVelocity = 0
        supportID = nil
        dropBelowY = nil
        intendedLandingID = nil
    }

    mutating func updateLedges(_ windowLedges: [Ledge]) {
        let oldSupport = support
        let ground = Ledge(id: 0, edge: .ground, minX: area.minX, maxX: area.maxX,
                           y: area.minY, carrierOrigin: area.origin)
        ledges = [ground] + windowLedges.filter { $0.y > area.minY + 1 && $0.y <= ceiling }
        if let intendedLandingID, !ledges.contains(where: { $0.id == intendedLandingID }) {
            self.intendedLandingID = nil
        }
        if let oldSupport, let replacement = ledges.first(where: {
            $0.id == oldSupport.id && $0.supports(feet.x + $0.carrierOrigin.x - oldSupport.carrierOrigin.x,
                                                 footHalfWidth: footHalfWidth)
        }) {
            feet.x += replacement.carrierOrigin.x - oldSupport.carrierOrigin.x
            feet.y = replacement.y
            verticalVelocity = 0
        } else if supportID != nil {
            supportID = nil
            verticalVelocity = 0
        }
    }

    mutating func advance(by elapsed: TimeInterval) {
        // Small steps keep falling pets from tunneling through a thin window rim.
        var remaining = min(max(elapsed, 0), 0.1)
        while remaining > 0.000001 {
            let dt = min(remaining, 1.0 / 120)
            step(CGFloat(dt))
            remaining -= dt
        }
    }

    private mutating func step(_ dt: CGFloat) {
        feet.x += horizontalVelocity * dt
        let margin = max(bodyHeight * 0.6, wrapHalfWidth ?? 0)
        let span = area.width + margin * 2
        var wrapped = false
        if span > 0 {
            while feet.x > area.maxX + margin { feet.x -= span; wrapped = true }
            while feet.x < area.minX - margin { feet.x += span; wrapped = true }
        }
        if wrapped && supportID != 0 { supportID = nil }

        if let current = support, dropBelowY == nil {
            feet.y = current.y
            verticalVelocity = 0
            return
        }
        supportID = nil
        let oldY = feet.y
        feet.y += verticalVelocity * dt - Self.gravity * dt * dt / 2
        verticalVelocity -= Self.gravity * dt

        if feet.y > ceiling {
            feet.y = ceiling
            verticalVelocity = min(0, verticalVelocity)
        }
        if verticalVelocity <= 0 {
            let targetHeight = ledges.first { $0.id == intendedLandingID }?.y
            let crossed = ledges.filter {
                $0.supports(feet.x, footHalfWidth: footHalfWidth) &&
                $0.y <= oldY + 0.001 && $0.y >= feet.y - 0.001 &&
                (dropBelowY == nil || $0.y < dropBelowY! - 2) &&
                (targetHeight == nil || $0.y <= targetHeight! + 0.001)
            }
            if let landing = crossed.max(by: { $0.y < $1.y }) {
                feet.y = landing.y
                verticalVelocity = 0
                supportID = landing.id
                dropBelowY = nil
                intendedLandingID = nil
            }
        }
        if feet.y <= area.minY {
            feet.y = area.minY
            verticalVelocity = 0
            supportID = 0
            dropBelowY = nil
            intendedLandingID = nil
        }
    }

    mutating func jump(height: CGFloat, horizontalSpeed: CGFloat = 0) {
        guard grounded else { return }
        let room = ceiling - feet.y
        guard room > 4 else { return }
        verticalVelocity = sqrt(2 * Self.gravity * min(max(height, 8), room))
        horizontalVelocity = horizontalSpeed
        supportID = nil
        dropBelowY = nil
        intendedLandingID = nil
    }

    /// Aim a ballistic jump at an actual higher rim, never at an arbitrary screen coordinate.
    @discardableResult
    mutating func jump(to ledge: Ledge) -> Bool {
        guard grounded, ledge.y > feet.y + 8, ledge.y < ceiling - 4 else { return false }
        let inset = min(footHalfWidth + 8, (ledge.maxX - ledge.minX) / 2)
        let targetX = min(ledge.maxX - inset, max(ledge.minX + inset, feet.x))
        let rise = ledge.y - feet.y
        let apexHeight = min(rise + 45, ceiling - feet.y)
        let launchSpeed = sqrt(2 * Self.gravity * apexHeight)
        let discriminant = max(0, launchSpeed * launchSpeed - 2 * Self.gravity * rise)
        let flightTime = (launchSpeed + sqrt(discriminant)) / Self.gravity
        let speed = (targetX - feet.x) / max(0.1, flightTime)
        guard abs(speed) <= 240 else { return false }
        jump(height: apexHeight, horizontalSpeed: speed)
        intendedLandingID = ledge.id
        return true
    }

    mutating func dropDown() {
        guard grounded, supportID != 0 else { return }
        dropBelowY = feet.y
        supportID = nil
        verticalVelocity = -80
        intendedLandingID = nil
    }

}
