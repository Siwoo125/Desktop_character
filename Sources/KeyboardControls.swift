import Foundation

struct KeyboardControls {
    enum Key: UInt16 { case a = 0, s = 1, d = 2, w = 13, space = 49, escape = 53 }
    enum Action { case jump, down, exit }
    private(set) var pressed: Set<Key> = []
    var running = false

    var horizontalAxis: CGFloat {
        (pressed.contains(.d) ? 1 : 0) - (pressed.contains(.a) ? 1 : 0)
    }
    var gait: GroundGait { running ? .running : .walking }

    @discardableResult
    mutating func keyDown(code: UInt16, isRepeat: Bool) -> Action? {
        guard let key = Key(rawValue: code) else { return nil }
        let fresh = pressed.insert(key).inserted
        guard fresh, !isRepeat else { return nil }
        switch key {
        case .w, .space: return .jump
        case .s: return .down
        case .escape: return .exit
        case .a, .d: return nil
        }
    }

    mutating func keyUp(code: UInt16) {
        if let key = Key(rawValue: code) { pressed.remove(key) }
    }
    mutating func reset() { pressed.removeAll(); running = false }
}
