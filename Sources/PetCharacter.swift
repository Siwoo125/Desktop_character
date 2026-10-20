import Foundation

enum PetCharacter: String, CaseIterable {
    case puppy
    case bonobono

    var displayName: String { self == .puppy ? "강아지" : "보노보노" }
    var idleActionTitle: String { self == .puppy ? "지금 꼬리 흔들기" : "지금 대기 동작 보기" }
    var statusSymbol: String { self == .puppy ? "pawprint.fill" : "drop.fill" }

    static func restored(from value: String?) -> PetCharacter {
        value.flatMap(Self.init(rawValue:)) ?? .puppy
    }
}
