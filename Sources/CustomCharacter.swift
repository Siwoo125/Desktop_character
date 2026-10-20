import Foundation
import ImageIO

enum CharacterSlot: String, CaseIterable, Codable {
    case standing, gaze, run, walk, walkLeft = "walk_left", idle, leap, cursorJump = "cursor_jump", cursorRoll = "cursor_roll"

    var title: String {
        switch self {
        case .standing: return "기본 정지 자세"
        case .gaze: return "커서 바라보기"
        case .run: return "오른쪽 달리기"
        case .walk: return "오른쪽 걷기"
        case .walkLeft: return "왼쪽 걷기 (선택)"
        case .idle: return "대기 · 눈 깜빡이기"
        case .leap: return "점프 · 하강"
        case .cursorJump: return "커서 잡기 점프"
        case .cursorRoll: return "커서를 잡고 구르기"
        }
    }
    var columns: Int { self == .standing ? 1 : self == .gaze ? 3 : 4 }
    var rows: Int { self == .standing || self == .gaze ? 1 : 2 }
    var required: Bool { self != .walkLeft }
    var filename: String { rawValue + ".png" }
    var guide: String {
        switch self {
        case .standing: return "투명 배경 PNG 1장 · 몸 전체가 보이게"
        case .gaze: return "가로 3칸 · 왼쪽 위 → 정면 위 → 오른쪽 위"
        case .walkLeft: return "4칸 × 2줄 · 없으면 오른쪽 걷기를 좌우 반전"
        case .leap: return "4칸 × 2줄 · 위의 점프 순서 설정에 맞추세요"
        case .cursorJump, .cursorRoll: return "4칸 × 2줄 · 커서는 그리지 마세요 · 미리보기에서 손 위치 조절 가능"
        default: return "4칸 × 2줄 · 윗줄 왼쪽부터, 다음 아랫줄 왼쪽부터"
        }
    }
    func example(_ character: PetCharacter, in root: URL) -> URL {
        let names: [CharacterSlot: String]
        let directory: URL
        if character == .bonobono {
            directory = root.appendingPathComponent("bonobono-sprites")
            names = [.standing: "01-standing.png", .gaze: "02-look-up.png", .run: "03-run-right.png",
                     .walk: "04-walk-right.png", .walkLeft: "05-walk-left.png", .idle: "06-idle.png",
                     .leap: "07-leap.png", .cursorJump: "09-jump-no-cursor.png", .cursorRoll: "11-roll-no-cursor.png"]
        } else {
            directory = root
            names = [.standing: "정지상태.png", .gaze: "세 방향으로 올려보는 픽셀 강아지.png", .run: "오른쪽 뛰는 상태.png",
                     .walk: "오른쪽으로 걷는 상태.png", .walkLeft: "오른쪽으로 걷는 상태.png", .idle: "유휴상태.png",
                     .leap: "픽셀 강아지의 힘찬 도약 스프라이트 시트.png", .cursorJump: "puppy-jump-8frames-no-cursor.png",
                     .cursorRoll: "puppy-roll-8frames-no-cursor.png"]
        }
        return directory.appendingPathComponent(names[self]!)
    }
}

struct CharacterGrip: Codable {
    var x: Double
    var y: Double
}

struct CustomCharacter: Codable {
    var version = 1
    var id: String
    var name: String
    var template: String
    var leapLayout: String
    var assets: [String: String]
    var grips: [String: [CharacterGrip]]
    var directory: URL? = nil

    enum CodingKeys: String, CodingKey {
        case version, id, name, template, assets, grips
        case leapLayout = "leap_layout"
    }
    var base: PetCharacter { PetCharacter.restored(from: template) }

    func validate() throws {
        guard version == 1, id.hasPrefix("custom-"), UUID(uuidString: String(id.dropFirst(7))) != nil,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 40,
              PetCharacter(rawValue: template) != nil, ["split", "continuous"].contains(leapLayout) else {
            throw AssetError.invalid("캐릭터 이름이나 저장 형식이 올바르지 않습니다.")
        }
        for slot in CharacterSlot.allCases {
            if slot.required || assets[slot.rawValue] != nil {
                guard assets[slot.rawValue] == slot.filename else {
                    throw AssetError.invalid("\(slot.title) 이미지가 필요합니다.")
                }
            }
        }
        for key in ["jump", "roll"] {
            guard let points = grips[key], points.count == 8,
                  points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else {
                throw AssetError.invalid("커서 손 위치는 프레임마다 이미지 안에 있어야 합니다.")
            }
        }
    }

    static func defaultGrips(_ character: PetCharacter) -> [String: [CharacterGrip]] {
        ["jump": (0..<8).map { CursorAttachment.jump($0, character: character) },
         "roll": (0..<8).map { CursorAttachment.roll($0, character: character) }]
            .mapValues { $0.map { CharacterGrip(x: Double($0.point.x), y: Double($0.point.y)) } }
    }
}

final class CustomCharacterStore {
    let root: URL
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DesktopFriends/characters", isDirectory: true)
    }

    static func exportExamples(template: PetCharacter, imagesRoot: URL, parent: URL) throws -> URL {
        let folder = parent.appendingPathComponent("캐릭터예시-\(template.rawValue)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            for slot in CharacterSlot.allCases where template != .puppy || slot != .walkLeft {
                try fm.copyItem(at: slot.example(template, in: imagesRoot), to: folder.appendingPathComponent(slot.filename))
            }
            for name in ["08-cursor-jump.png", "10-cursor-roll.png"] {
                try fm.copyItem(at: imagesRoot.appendingPathComponent("bonobono-sprites/" + name), to: folder.appendingPathComponent("reference-" + name))
            }
            let instructions = """
            캐릭터 만들기
            예시를 참고해 새 PNG를 준비한 뒤 앱 메뉴 → 캐릭터 생성 → 이미지 선택으로 등록하세요.
            배경은 투명하게, 몸 전체는 각 칸 안에 넣어 주세요. 모든 칸에 자세가 있어야 합니다.
            8프레임: 4칸 × 2줄, 윗줄 왼쪽 → 오른쪽, 아랫줄 왼쪽 → 오른쪽. 예: 2048 × 1024.
            standing.png: 정지 자세 1장 / gaze.png: 가로 3칸 (왼쪽 위, 정면 위, 오른쪽 위).
            walk_left.png는 선택이며 없으면 오른쪽 걷기를 좌우 반전합니다. 강아지 예시에는 전용 왼쪽 걷기 이미지가 없으므로 포함하지 않습니다. 나머지 8종은 필수입니다.
            leap.png: \(template == .puppy ? "윗줄 위로 점프, 아랫줄 하강. 각 줄 준비 → 공중 → 착지 직전 → 착지" : "준비 → 발구르기 → 상승 → 정점 → 하강 → 착지 직전 → 착지 → 회복"). 앱의 점프 시트 순서도 맞춰 주세요.
            cursor_jump.png / cursor_roll.png에는 커서를 그리지 마세요. 미리보기에서 프레임을 고르고 손을 클릭해 접점을 맞추세요. 점프 5~8번, 구르기 전체에 적용됩니다.
            reference-*는 커서가 그려진 참고용 이미지이므로 실제 동작으로 등록하지 않습니다.
            이름을 직접 입력하거나 이름 추천을 누른 뒤 ‘저장하고 사용’을 누르면 새 캐릭터 한 마리를 띄웁니다.
            """
            try instructions.write(to: folder.appendingPathComponent("만드는방법.txt"), atomically: true, encoding: .utf8)
            return folder
        } catch { try? fm.removeItem(at: folder); throw error }
    }

    func all() -> [CustomCharacter] {
        let directories = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return directories.compactMap { directory -> CustomCharacter? in
            guard var profile = try? JSONDecoder().decode(CustomCharacter.self, from: Data(contentsOf: directory.appendingPathComponent("character.json"))),
                  profile.id == directory.lastPathComponent, (try? profile.validate()) != nil else { return nil }
            profile.directory = directory
            return profile
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func delete(_ id: String) throws {
        guard PetCharacter(rawValue: id) == nil, id.hasPrefix("custom-"), UUID(uuidString: String(id.dropFirst(7))) != nil,
              all().contains(where: { $0.id == id }) else { throw AssetError.invalid("직접 만든 캐릭터만 삭제할 수 있습니다. 강아지와 보노보노는 삭제할 수 없습니다.") }
        let trash = root.appendingPathComponent(".trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root.appendingPathComponent(id), to: trash.appendingPathComponent(id + "-" + UUID().uuidString))
    }

    func suggestedName() -> String {
        let used = Set(all().map { $0.name.lowercased() })
        let adjectives = ["포근한", "느긋한", "반짝이는", "말랑한", "산뜻한", "씩씩한", "졸린", "장난꾸러기"]
        let names = ["모찌", "토리", "구름이", "별이", "콩이", "두리", "루루", "몽이"]
        for _ in 0..<100 {
            let name = "\(adjectives.randomElement()!) \(names.randomElement()!)"
            if !used.contains(name.lowercased()) { return name }
        }
        var index = 1
        while used.contains("나의 캐릭터 \(index)") { index += 1 }
        return "나의 캐릭터 \(index)"
    }

    static func validatePNG(_ url: URL, slot: CharacterSlot) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetType(source) as String? == "public.png",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw AssetError.invalid("\(slot.title): PNG 파일을 선택해 주세요.")
        }
        guard width >= slot.columns * 8, height >= slot.rows * 8,
              width <= 8192, height <= 8192, width * height <= 16_777_216 else {
            throw AssetError.invalid("\(slot.title): 각 칸은 최소 8픽셀, 전체 이미지는 8192픽셀·1600만 화소 이하여야 합니다.")
        }
        guard try SpriteAtlas.hasTransparentBackground(url) else {
            throw AssetError.invalid("배경을 투명하게 만든 PNG를 선택해 주세요.")
        }
        _ = try SpriteAtlas.customFrames(url, slot: slot)
    }

    func create(name: String, template: PetCharacter, leapLayout: String,
                files: [CharacterSlot: URL], grips: [String: [CharacterGrip]]) throws -> (CustomCharacter, SpriteAtlas) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !cleanName.isEmpty, cleanName.count <= 40 else { throw AssetError.invalid("캐릭터 이름을 1~40자로 입력해 주세요.") }
        guard !all().contains(where: { $0.name.caseInsensitiveCompare(cleanName) == .orderedSame }) else {
            throw AssetError.invalid("같은 이름의 캐릭터가 있습니다. 다른 이름을 입력해 주세요.")
        }
        for slot in CharacterSlot.allCases where slot.required && files[slot] == nil {
            throw AssetError.invalid("\(slot.title) 이미지를 먼저 선택해 주세요.")
        }
        let id = "custom-" + UUID().uuidString.lowercased()
        var profile = CustomCharacter(id: id, name: cleanName, template: template.rawValue, leapLayout: leapLayout,
            assets: Dictionary(uniqueKeysWithValues: files.keys.map { ($0.rawValue, $0.filename) }), grips: grips)
        try profile.validate()
        for (slot, url) in files { try Self.validatePNG(url, slot: slot) }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".pending-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        var committed = false
        defer { if !committed { try? fm.removeItem(at: staging) } }
        for (slot, url) in files { try fm.copyItem(at: url, to: staging.appendingPathComponent(slot.filename)) }
        profile.directory = staging
        let atlas = try SpriteAtlas(custom: profile)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profile).write(to: staging.appendingPathComponent("character.json"), options: .atomic)
        let destination = root.appendingPathComponent(id, isDirectory: true)
        try fm.moveItem(at: staging, to: destination)
        committed = true
        profile.directory = destination
        return (profile, atlas)
    }
}
