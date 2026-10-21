import AppKit

struct PetInstance: Codable {
    var id = UUID().uuidString.lowercased()
    var character: String
    var baseHeight: Double = 60
    var scale: Double = 1
    var x: Double? = nil
    var y: Double? = nil
    enum CodingKeys: String, CodingKey { case id, character, scale, x, y; case baseHeight = "base_height" }
    var valid: Bool {
        UUID(uuidString: id) != nil && (PetCharacter(rawValue: character) != nil ||
            (character.hasPrefix("custom-") && UUID(uuidString: String(character.dropFirst(7))) != nil)) &&
        baseHeight.isFinite && (20...160).contains(baseHeight) && PetSizing.scales.contains(scale) &&
        (x?.isFinite ?? true) && (y?.isFinite ?? true)
    }
}

struct PetRosterStore {
    let defaults: UserDefaults
    func load() -> [PetInstance] {
        if let data = defaults.data(forKey: "petInstancesV1"), let saved = try? JSONDecoder().decode([PetInstance].self, from: data) {
            return saved.filter(\.valid)
        }
        let sizing = PetSizing(savedBase: defaults.double(forKey: "dogBaseHeight"), savedScale: defaults.double(forKey: "dogScale"), legacyHeight: defaults.double(forKey: "dogHeight"))
        return [PetInstance(character: defaults.string(forKey: "petCharacter") ?? "puppy", baseHeight: Double(sizing.baseHeight), scale: sizing.scale,
            x: defaults.object(forKey: "dogX") == nil ? nil : defaults.double(forKey: "dogX"),
            y: defaults.object(forKey: "dogY") == nil ? nil : defaults.double(forKey: "dogY"))]
    }
    func save(_ instances: [PetInstance]) {
        if let data = try? JSONEncoder().encode(instances) { defaults.set(data, forKey: "petInstancesV1") }
    }
}

@MainActor final class PetCollection: NSObject, NSMenuDelegate {
    let atlases: [PetCharacter: SpriteAtlas]
    let store: CustomCharacterStore
    private(set) var pets: [DesktopDog] = []
    weak var cursorOwner: DesktopDog?
    private var cached: [String: SpriteAtlas] = [:]
    private var statusItem: NSStatusItem?
    private(set) var library: CharacterLibraryWindow?
    private var creator: CharacterCreator?
    private let roster: PetRosterStore
    private let persist: Bool
    private var restoring = false
    private var shuttingDown = false
    private var trackingMenus: Set<ObjectIdentifier> = []
    private(set) var uiPaused = false

    init(atlases: [PetCharacter: SpriteAtlas], store: CustomCharacterStore = CustomCharacterStore(), defaults: UserDefaults = .standard, persist: Bool = true) {
        self.atlases = atlases; self.store = store; roster = PetRosterStore(defaults: defaults); self.persist = persist
        super.init()
    }
    func restore(_ states: [PetInstance]? = nil) {
        restoring = true
        for state in states ?? roster.load() where state.valid {
            do { _ = try spawn(state) } catch { fputs("캐릭터 복원 생략: \(error.localizedDescription)\n", stderr) }
        }
        ensureDefaultPet()
        restoring = false; changed()
    }
    func ensureDefaultPet() {
        if pets.isEmpty { addCharacter("puppy") }
    }
    @discardableResult func spawn(_ original: PetInstance) throws -> DesktopDog {
        guard original.valid else { throw AssetError.invalid("캐릭터 설정이 올바르지 않습니다.") }
        var state = original
        if pets.contains(where: { $0.instanceID == state.id }) { state.id = UUID().uuidString.lowercased() }
        if state.x == nil, let screen = NSScreen.main ?? NSScreen.screens.first {
            state.x = screen.visibleFrame.maxX - 180 - Double(pets.count % 8) * 75
            state.y = screen.visibleFrame.minY - 6
        }
        let pet = DesktopDog()
        try pet.start(state: state, collection: self)
        pets.append(pet); changed()
        return pet
    }
    func addCharacter(_ id: String, scale: Double = 1, baseHeight: Double = 60) {
        do { _ = try spawn(PetInstance(character: id, baseHeight: baseHeight, scale: scale)) } catch { showError(error) }
    }
    func remove(_ pet: DesktopDog) {
        guard pets.contains(where: { $0 === pet }) else { return }
        pet.shutdown()
        pets.removeAll { $0 === pet }
        changed()
    }
    func removeOne(_ character: String) {
        if let pet = pets.last(where: { $0.selectedCharacterID == character }) { remove(pet) }
    }
    func customAtlas(_ profile: CustomCharacter) throws -> SpriteAtlas {
        if let value = cached[profile.id] { return value }
        let value = try SpriteAtlas(custom: profile); cached[profile.id] = value; return value
    }
    func canCatchCursor(_ pet: DesktopDog) -> Bool { cursorOwner == nil || cursorOwner === pet }
    func save() {
        guard persist, !restoring, !shuttingDown else { return }
        roster.save(pets.map(\.savedInstance))
    }
    func changed() {
        guard !restoring, !shuttingDown else { return }
        refreshStatus(); library?.refresh(rows: rows()); save()
    }
    func makeStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        refreshStatus()
    }
    private func refreshStatus() {
        guard let statusItem else { return }
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "캐릭터 관리 (+ / −)…", action: #selector(openLibrary), keyEquivalent: "").target = self
        menu.addItem(withTitle: "캐릭터 생성…", action: #selector(openCreator), keyEquivalent: "").target = self
        if !pets.isEmpty { menu.addItem(.separator()) }
        for (index, pet) in pets.enumerated() {
            let item = NSMenuItem(title: "\(pet.characterName) · \(index + 1)", action: nil, keyEquivalent: "")
            // Detach a submenu from its previous status-menu parent before reusing it.
            pet.contextMenu.supermenu?.items.first(where: { $0.submenu === pet.contextMenu })?.submenu = nil
            item.submenu = pet.contextMenu; menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "모두 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "바탕화면 친구")
        statusItem.button?.title = " \(pets.count)"
        statusItem.button?.toolTip = "바탕화면 친구 \(pets.count)마리 · + / −로 관리"
    }
    private func rows() -> [CharacterLibraryRow] {
        var result = PetCharacter.allCases.map { CharacterLibraryRow(id: $0.rawValue, name: $0.displayName, image: atlases[$0]!.resting.image, count: count($0.rawValue), builtin: true) }
        result += store.all().map { profile in
            CharacterLibraryRow(id: profile.id, name: profile.name, image: (try? customAtlas(profile))?.resting.image, count: count(profile.id), builtin: false)
        }
        return result
    }
    func count(_ id: String) -> Int { pets.filter { $0.selectedCharacterID == id }.count }
    private func updateSuspension() {
        uiPaused = library != nil || creator != nil || !trackingMenus.isEmpty
        for pet in pets { pet.collectionPausedChanged() }
    }
    func menuWillOpen(_ menu: NSMenu) { trackingMenus.insert(ObjectIdentifier(menu)); updateSuspension() }
    func menuDidClose(_ menu: NSMenu) { trackingMenus.remove(ObjectIdentifier(menu)); updateSuspension() }
    @objc func openLibrary() {
        if let library { NSApp.activate(ignoringOtherApps: true); library.showWindow(nil); library.window?.makeKeyAndOrderFront(nil); return }
        let window = CharacterLibraryWindow()
        window.onAdd = { [weak self] in self?.addCharacter($0) }
        window.onRemove = { [weak self] in self?.removeOne($0) }
        window.onDelete = { [weak self] in self?.confirmDelete($0) }
        window.onCreate = { [weak self] in self?.openCreator() }
        window.onClosed = { [weak self] in self?.library = nil; self?.updateSuspension() }
        library = window
        window.refresh(rows: rows()); updateSuspension()
        NSApp.activate(ignoringOtherApps: true); window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil)
    }
    @objc func openCreator() {
        if let creator { NSApp.activate(ignoringOtherApps: true); creator.showWindow(nil); creator.window?.makeKeyAndOrderFront(nil); return }
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("img") else { return }
        let window = CharacterCreator(store: store, imagesRoot: root, template: .puppy)
        window.onCreated = { [weak self] profile, atlas in
            guard let self else { return }
            self.cached[profile.id] = atlas
            for pet in self.pets { pet.refreshLibrary() }
            self.addCharacter(profile.id)
        }
        window.onClosed = { [weak self] in self?.creator = nil; self?.updateSuspension() }
        creator = window; updateSuspension()
        NSApp.activate(ignoringOtherApps: true); window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil)
    }
    private func confirmDelete(_ id: String) {
        guard let profile = store.all().first(where: { $0.id == id }) else { return }
        let alert = NSAlert(); alert.messageText = "‘\(profile.name)’ 캐릭터를 삭제할까요?"
        alert.informativeText = "보관함에서 삭제하고 화면에 있는 이 캐릭터 \(count(id))마리도 모두 내립니다. 강아지와 보노보노는 삭제되지 않습니다."
        alert.addButton(withTitle: "삭제"); alert.addButton(withTitle: "취소")
        if alert.runModal() == .alertFirstButtonReturn {
            do { try deleteCharacter(id) } catch { showError(error) }
        }
    }
    func deleteCharacter(_ id: String) throws {
        try store.delete(id)
        for pet in pets.filter({ $0.selectedCharacterID == id }) { remove(pet) }
        cached.removeValue(forKey: id)
        for pet in pets { pet.refreshLibrary() }
        changed()
    }
    private func showError(_ error: Error) {
        let alert = NSAlert(); alert.messageText = "캐릭터를 변경하지 못했습니다."; alert.informativeText = error.localizedDescription; alert.runModal()
    }
    func focusLost() { for pet in pets { pet.focusLost() } }
    func shutdown() {
        save(); shuttingDown = true
        library?.onClosed = nil; library?.close(); library = nil
        creator?.onClosed = nil; creator?.close(); creator = nil
        for pet in pets { pet.shutdown() }
        pets.removeAll()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }
}

@main @MainActor final class DesktopFriends: NSObject, NSApplicationDelegate {
    private var collection: PetCollection?
    static func main() {
        let delegate = DesktopFriends(), app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        DesktopDog.makeMainMenu()
        do {
            let root = Bundle.main.resourceURL!.appendingPathComponent("img")
            var atlases: [PetCharacter: SpriteAtlas] = [:]
            for character in PetCharacter.allCases { atlases[character] = try SpriteAtlas(directory: root, character: character) }
            if CommandLine.arguments.contains("--self-test") {
                try DesktopDog().runChecks(atlases: atlases)
                if CommandLine.arguments.contains("--collection-window-check") { try CollectionChecks.run(atlases: atlases, imagesRoot: root) }
                if CommandLine.arguments.contains("--creator-window-check") {
                    Task { @MainActor in
                        do { try await AIMotionChecks.run(imagesRoot: root) }
                        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
                        NSApp.terminate(nil)
                    }
                } else { NSApp.terminate(nil) }
                return
            }
            let collection = PetCollection(atlases: atlases); self.collection = collection
            collection.makeStatusMenu()
            if let index = CommandLine.arguments.firstIndex(of: "--character"), CommandLine.arguments.indices.contains(index + 1) {
                collection.restore([PetInstance(character: CommandLine.arguments[index + 1])])
            } else { collection.restore() }
        } catch {
            if CommandLine.arguments.contains("--self-test") { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
            let alert = NSAlert(); alert.messageText = "캐릭터를 불러오지 못했습니다."; alert.informativeText = error.localizedDescription; alert.runModal(); NSApp.terminate(nil)
        }
    }
    func applicationDidResignActive(_ notification: Notification) { collection?.focusLost() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        collection?.ensureDefaultPet()
        return true
    }
    func applicationWillTerminate(_ notification: Notification) { collection?.shutdown() }
}
