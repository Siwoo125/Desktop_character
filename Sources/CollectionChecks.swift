import AppKit

@MainActor enum CollectionChecks {
    static func run(atlases: [PetCharacter: SpriteAtlas], imagesRoot: URL) throws {
        func check(_ value: Bool, _ message: String) throws { if !value { throw AssetError.invalid("여러 캐릭터 검사: \(message)") } }
        let fm = FileManager.default, domain = "DesktopFriends.CollectionCheck." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        let temporary = fm.temporaryDirectory.appendingPathComponent(domain)
        let store = CustomCharacterStore(root: temporary)
        defer { defaults.removePersistentDomain(forName: domain); try? fm.removeItem(at: temporary) }
        let freshStartup = PetCollection(atlases: atlases, store: store, defaults: defaults, persist: false)
        freshStartup.restore()
        try check(freshStartup.pets.count == 1 && freshStartup.count("puppy") == 1, "첫 실행 시 기본 강아지 한 마리 생성")
        freshStartup.shutdown()
        let collection = PetCollection(atlases: atlases, store: store, defaults: defaults)
        defer { collection.shutdown() }
        let puppy = try collection.spawn(PetInstance(character: "puppy", scale: 0.5, x: 100, y: 50))
        _ = try collection.spawn(PetInstance(character: "bonobono", scale: 1.5, x: 300, y: 60))
        _ = try collection.spawn(PetInstance(character: "puppy", scale: 2, x: 500, y: 80))
        try check(collection.pets.count == 3 && collection.count("puppy") == 2 && collection.count("bonobono") == 1, "서로 다른 캐릭터·같은 캐릭터 동시 표시")
        try check(Set(collection.pets.map(\.instanceID)).count == 3, "복사본별 독립 ID")
        try check(collection.pets.map { $0.savedInstance.scale } == [0.5, 1.5, 2], "복사본별 배율")
        collection.openLibrary()
        try check(collection.library?.deleteButtons["puppy"]?.isEnabled == false && collection.library?.deleteButtons["bonobono"]?.isEnabled == false, "기본 캐릭터 삭제 버튼 비활성")
        collection.library?.addButtons["bonobono"]?.performClick(nil)
        try check(collection.count("bonobono") == 2, "+ 버튼은 다른 캐릭터를 유지하며 한 마리 추가")
        collection.library?.removeButtons["puppy"]?.performClick(nil)
        try check(collection.count("puppy") == 1 && collection.pets.contains { $0 === puppy }, "− 버튼은 해당 종류 한 마리만 내림")
        collection.library?.close()
        try check(!collection.uiPaused, "관리 창 닫기 후 자동 동작 재개")
        try puppy.verifyCollectionIsolation(with: collection.pets.first { $0 !== puppy }!)
        let files = Dictionary(uniqueKeysWithValues: CharacterSlot.allCases.filter(\.required).map { ($0, $0.example(.bonobono, in: imagesRoot)) })
        let (profile, _) = try store.create(name: "삭제 검사 친구", template: .bonobono, leapLayout: "continuous", files: files, grips: CustomCharacter.defaultGrips(.bonobono))
        _ = try collection.spawn(PetInstance(character: profile.id)); _ = try collection.spawn(PetInstance(character: profile.id))
        collection.save()
        let snapshot = PetRosterStore(defaults: defaults).load()
        try check(snapshot.count == collection.pets.count && snapshot.filter { $0.character == profile.id }.count == 2, "같은 캐릭터 복사본 저장")
        let restored = PetCollection(atlases: atlases, store: store, defaults: defaults, persist: false)
        restored.restore()
        try check(restored.pets.count == snapshot.count && restored.count(profile.id) == 2, "모든 종류·중복 캐릭터 재실행 복원")
        restored.shutdown()
        for id in ["puppy", "bonobono", "../puppy"] {
            var rejected = false
            do { try collection.deleteCharacter(id) } catch { rejected = true }
            try check(rejected, "기본 캐릭터·잘못된 ID 삭제 차단")
        }
        try collection.deleteCharacter(profile.id)
        try check(collection.count(profile.id) == 0 && store.all().isEmpty && collection.count("bonobono") > 0, "사용자 캐릭터 삭제 시 해당 복사본만 전부 내림·기본 캐릭터 보존")
        for pet in collection.pets { collection.remove(pet) }
        try check(PetRosterStore(defaults: defaults).load().isEmpty, "0마리 상태 저장")
        let emptyStartup = PetCollection(atlases: atlases, store: store, defaults: defaults, persist: false)
        emptyStartup.restore()
        try check(emptyStartup.pets.count == 1 && emptyStartup.count("puppy") == 1, "0마리로 종료한 뒤 실행하면 기본 강아지 한 마리 생성")
        emptyStartup.ensureDefaultPet()
        try check(emptyStartup.pets.count == 1, "앱을 다시 열어도 기본 강아지 중복 생성 안 함")
        emptyStartup.removeOne("puppy")
        try check(emptyStartup.pets.isEmpty, "실행 중에는 마지막 강아지도 −로 내릴 수 있음")
        emptyStartup.ensureDefaultPet()
        try check(emptyStartup.count("puppy") == 1, "0마리인 실행 중 앱을 다시 열면 기본 강아지 생성")
        emptyStartup.shutdown()
        collection.openLibrary()
        try check(collection.library?.removeButtons["puppy"]?.isEnabled == false, "0마리는 − 비활성")
        collection.library?.addButtons["puppy"]?.performClick(nil)
        try check(collection.pets.count == 1, "모두 내린 뒤 +로 다시 추가")
        print("PASS: 여러 종류·중복 복사본·독립 크기/물리·+ / − UI·빈 상태 시작 시 기본 강아지·목록 저장·사용자 캐릭터 삭제·기본 캐릭터 보호·커서 소유권")
    }
}
