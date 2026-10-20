import Foundation

struct CursorGaze {
    enum Direction: Int { case left, up, right }
    private(set) var direction: Direction = .up

    mutating func update(cursor: CGPoint, head: CGPoint, height: CGFloat) {
        let dx = cursor.x - head.x
        let dy = max(0, cursor.y - head.y)
        // Widen the central cone for distant cursors, with a small dead band at the head.
        let boundary = max(height * 0.22, dy * 0.4)
        let returnBoundary = boundary * 0.72
        switch direction {
        case .up:
            if dx < -boundary { direction = .left }
            else if dx > boundary { direction = .right }
        case .left:
            if dx > boundary { direction = .right }
            else if dx > -returnBoundary { direction = .up }
        case .right:
            if dx < -boundary { direction = .left }
            else if dx < returnBoundary { direction = .up }
        }
    }
}
