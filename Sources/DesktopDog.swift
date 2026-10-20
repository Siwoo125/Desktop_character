import AppKit

@MainActor
final class DogView: NSView {
    var sprite: DogSprite
    var dogHeight: CGFloat
    var mirrored = false
    var contextMenu: NSMenu?
    var didMove: (() -> Void)?
    var willDrag: (() -> Void)?
    var constrainOrigin: ((CGPoint) -> CGPoint)?
    var focusKeyboard: (() -> Void)?
    var handleKeyboard: ((NSEvent) -> Bool)?
    var keyboardFocused = false
    var cursorAttachment: CursorAttachment?
    var renderOffset = CGPoint.zero
    private var dragOffset: CGPoint?

    init(sprite: DogSprite, height: CGFloat) {
        self.sprite = sprite
        dogHeight = height
        super.init(frame: .zero)
        toolTip = "드래그해서 이동 · 우클릭으로 메뉴 열기"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill(using: .copy)
        let canvas = bounds.offsetBy(dx: renderOffset.x, dy: renderOffset.y)
        sprite.draw(in: canvas, height: dogHeight, mirrored: mirrored)
        cursorAttachment?.draw(in: canvas, sprite: sprite, height: dogHeight, mirrored: mirrored)
        if keyboardFocused {
            NSColor.systemTeal.withAlphaComponent(0.7).setStroke()
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
            outline.lineWidth = 1.5
            outline.stroke()
        }
    }

    override func keyDown(with event: NSEvent) {
        if handleKeyboard?(event) != true { super.keyDown(with: event) }
    }
    override func keyUp(with event: NSEvent) {
        if handleKeyboard?(event) != true { super.keyUp(with: event) }
    }
    override func flagsChanged(with event: NSEvent) {
        if handleKeyboard?(event) != true { super.flagsChanged(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        focusKeyboard?()
        willDrag?()
        let mouse = NSEvent.mouseLocation
        dragOffset = CGPoint(x: mouse.x - window.frame.minX, y: mouse.y - window.frame.minY)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragOffset else { return }
        let mouse = NSEvent.mouseLocation
        let proposed = CGPoint(x: mouse.x - dragOffset.x, y: mouse.y - dragOffset.y)
        window.setFrameOrigin(constrainOrigin?(proposed) ?? proposed)
    }
    override func mouseUp(with event: NSEvent) {
        dragOffset = nil
        didMove?()
    }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu }
}

@MainActor
final class DogPanel: NSPanel {
    var keyboardEnabled = false
    override var canBecomeKey: Bool { keyboardEnabled }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DesktopDog: NSObject, NSMenuDelegate, NSWindowDelegate {
    weak var collection: PetCollection?
    private(set) var instanceID = UUID().uuidString.lowercased()
    private var initialOrigin: CGPoint?
    private var closed = false
    private var atlas: SpriteAtlas!
    private var atlases: [PetCharacter: SpriteAtlas] = [:]
    private var character = PetCharacter.puppy
    private var customStore = CustomCharacterStore()
    private var customProfiles: [CustomCharacter] = []
    private var customAtlases: [String: SpriteAtlas] = [:]
    private var currentCustom: CustomCharacter?
    var selectedCharacterID: String { currentCustom?.id ?? character.rawValue }
    var characterName: String { currentCustom?.name ?? character.displayName }
    var contextMenu: NSMenu { menu }
    private var panel: DogPanel!
    private var dogView: DogView!
    private var timer: Timer?
    private var roamingTimer: Timer?
    private var movementTimer: Timer?
    private var physics: PetPhysics!
    private var hop: HopPlayback?
    private var pendingHop: HopAction?
    private var landingWalkVelocity: CGFloat = 0
    private var lastPhysicsTime: TimeInterval = 0
    private var nextSceneRefresh: TimeInterval = 0
    private var walkUntil: TimeInterval = 0
    private var preferDescending = false
    private var isClimbing = false
    private var approachingClimb = false
    private var climbedWindows: Set<UInt64> = []
    private var actionCount = 0
    private var dragging = false
    private var menuTracking = false
    private var sleeping = false
    private var playback = IdlePlayback()
    private var paused = false
    private var hidden = false
    private var gait = GroundGait.walking
    private var cursorGaze = CursorGaze()
    private var cursorPlay: CursorPlay?
    private var heldCursor = HeldCursor()
    private var lastCursor = NSEvent.mouseLocation
    private var cursorStillSince: TimeInterval = 0
    private static let cursorPlayInterval: TimeInterval = 60
    private var nextCursorPlay = ProcessInfo.processInfo.systemUptime + DesktopDog.cursorPlayInterval
    private var cursorRequestUntil: TimeInterval = 0
    private var cursorPlayBegan: TimeInterval = 0
    private var keyboardMode = false
    private var controls = KeyboardControls()
    private var previousApplication: NSRunningApplication?
    private var sizing = PetSizing(savedBase: 0, savedScale: 0, legacyHeight: 0)
    private var dogHeight: CGFloat { sizing.height }
    private let menu = NSMenu()
    private var pauseItem: NSMenuItem!
    private var hideItem: NSMenuItem!
    private var keyboardItem: NSMenuItem!
    private var sizeItems: [NSMenuItem] = []
    private var characterItems: [PetCharacter: NSMenuItem] = [:]
    private var titleItem: NSMenuItem!
    private var idleItem: NSMenuItem!
    private var characterMenu: NSMenu!
    private var customItems: [String: NSMenuItem] = [:]
    private var customSeparator: NSMenuItem?

    func start(state: PetInstance, collection: PetCollection) throws {
        self.collection = collection
        instanceID = state.id
        atlases = collection.atlases
        customStore = collection.store
        customProfiles = customStore.all()
        if let builtin = PetCharacter(rawValue: state.character) {
            character = builtin; atlas = atlases[builtin]
        } else {
            guard let profile = customProfiles.first(where: { $0.id == state.character }) else {
                throw AssetError.invalid("캐릭터를 찾을 수 없습니다.")
            }
            currentCustom = profile; character = profile.base
            atlas = try collection.customAtlas(profile)
            customAtlases[profile.id] = atlas
        }
        sizing = PetSizing(savedBase: state.baseHeight, savedScale: state.scale, legacyHeight: 0)
        if let x = state.x, let y = state.y { initialOrigin = CGPoint(x: x, y: y) }
        makeMenu(); makePanel(); restartActivity()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    func runChecks(atlases: [PetCharacter: SpriteAtlas]) throws {
        self.atlases = atlases
        if let index = CommandLine.arguments.firstIndex(of: "--character"), CommandLine.arguments.indices.contains(index + 1),
           let requested = PetCharacter(rawValue: CommandLine.arguments[index + 1]) { character = requested }
        atlas = atlases[character]
        defer { shutdown() }
        try verify()
    }

    var savedInstance: PetInstance {
        PetInstance(id: instanceID, character: selectedCharacterID, baseHeight: Double(sizing.baseHeight), scale: sizing.scale,
                    x: panel.map { Double($0.frame.minX) }, y: panel.map { Double($0.frame.minY) })
    }

    func refreshLibrary() {
        customProfiles = customStore.all()
        customAtlases = customAtlases.filter { key, _ in customProfiles.contains { $0.id == key } }
        rebuildCustomMenu(); updateMenu()
    }

    func collectionPausedChanged() { stopActivity(); restartActivity() }
    func focusLost() { resetControlKeys() }

    func verifyCollectionIsolation(with other: DesktopDog) throws {
        func check(_ value: Bool, _ message: String) throws { if !value { throw AssetError.invalid("독립 캐릭터 검사: \(message)") } }
        try check(roamingTimer != nil && other.roamingTimer != nil && roamingTimer!.fireDate != other.roamingTimer!.fireDate,
                  "같이 재개해도 캐릭터별 다음 행동 시각이 다름")
        stopActivity(); other.stopActivity()
        let before = other.physics.feet
        physics.horizontalVelocity = 90
        physics.advance(by: 0.1)
        try check(other.physics.feet == before && other.physics.horizontalVelocity == 0, "한 캐릭터 이동이 다른 캐릭터 물리를 바꾸지 않음")
        var hides = 0, shows = 0
        heldCursor = HeldCursor(hide: { hides += 1; return true }, show: { shows += 1 })
        physics.teleport(to: CGPoint(x: physics.area.midX, y: physics.area.minY)); physics.updateLedges([]); physics.advance(by: 1.0 / 120)
        other.physics.teleport(to: CGPoint(x: other.physics.area.midX + 50, y: other.physics.area.minY)); other.physics.updateLedges([]); other.physics.advance(by: 1.0 / 120)
        let target = CGPoint(x: physics.feet.x + 80, y: physics.feet.y + 200)
        try check(beginCursorPlay(at: target, automatic: false), "첫 캐릭터 커서 잡기 시작")
        try check(!other.beginCursorPlay(at: target, automatic: false), "다른 캐릭터 동시 커서 잡기 차단")
        for _ in 0..<100 { if heldCursor.hidden { break }; advanceCursorPlay(by: 1.0 / 30, cursor: target, buttons: 0) }
        try check(heldCursor.hidden, "제거 전 커서 접점 도달")
        collection?.remove(self)
        try check(hides == 1 && shows == 1 && collection?.cursorOwner == nil && movementTimer == nil, "− 제거 시 커서 복구·타이머 해제·소유권 반환")
    }

    func shutdown() {
        guard !closed else { return }
        closed = true
        stopActivity(); cancelHop()
        keyboardMode = false; panel?.keyboardEnabled = false
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        panel?.delegate = nil
        panel?.close()
    }

    private func makePanel() {
        panel = DogPanel(contentRect: CGRect(origin: .zero, size: windowSize),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .none
        panel.delegate = self
        dogView = DogView(sprite: atlas.resting, height: dogHeight)
        dogView.contextMenu = menu
        dogView.focusKeyboard = { [weak self] in self?.takeKeyboardFocus() }
        dogView.handleKeyboard = { [weak self] event in self?.handleControlKey(event) ?? false }
        dogView.willDrag = { [weak self] in
            guard let self else { return }
            self.dragging = true
            self.cancelHop()
            self.stopActivity()
        }
        dogView.constrainOrigin = { [weak self] proposed in
            guard let self, let screen = self.currentScreen else { return proposed }
            return self.clampedOrigin(proposed, in: screen.visibleFrame)
        }
        dogView.didMove = { [weak self] in
            guard let self else { return }
            self.dragging = false
            self.clampPosition()
            self.physics.area = self.currentScreen?.visibleFrame ?? self.physics.area
            self.physics.teleport(to: CGPoint(x: self.panel.frame.midX, y: self.panel.frame.minY + 6))
            self.refreshScene()
            self.savePosition()
            self.restartActivity()
        }
        panel.contentView = dogView
        if let initialOrigin {
            panel.setFrameOrigin(initialOrigin)
            clampPosition()
        } else if let screen = currentScreen {
            panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.maxX - panel.frame.width - 48,
                                         y: screen.visibleFrame.minY))
        }
        if let screen = currentScreen {
            physics = PetPhysics(feet: CGPoint(x: panel.frame.midX, y: panel.frame.minY + 6),
                                 area: screen.visibleFrame, bodyHeight: dogHeight)
            physics.wrapHalfWidth = dogHeight * atlas.windowWidthRatio / 2
            refreshScene()
        }
        panel.orderFrontRegardless()
    }

    private var windowSize: CGSize {
        CGSize(width: dogHeight * (atlas?.windowWidthRatio ?? 1.25) + 12, height: dogHeight + 12)
    }

    private func addItem(_ title: String, action: Selector, key: String = "", in destination: NSMenu? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        (destination ?? menu).addItem(item)
        return item
    }

    private func makeMenu() {
        menu.delegate = self
        titleItem = NSMenuItem(title: "바탕화면 친구", action: nil, keyEquivalent: "")
        menu.addItem(titleItem)
        _ = addItem("캐릭터 관리 (+ / −)…", action: #selector(manageCharacters))
        _ = addItem("+ 같은 캐릭터 추가", action: #selector(addCopy))
        _ = addItem("− 이 캐릭터 없애기", action: #selector(removeCopy))
        _ = addItem("캐릭터 생성…", action: #selector(createCharacter))
        characterMenu = NSMenu(title: "캐릭터 선택")
        let characterParent = NSMenuItem(title: "캐릭터 선택", action: nil, keyEquivalent: "")
        characterParent.submenu = characterMenu
        menu.addItem(characterParent)
        for choice in PetCharacter.allCases {
            let item = NSMenuItem(title: choice.displayName, action: #selector(changeCharacter(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            characterMenu.addItem(item)
            characterItems[choice] = item
        }
        rebuildCustomMenu()
        menu.addItem(.separator())
        let actionsMenu = NSMenu(title: "동작 예시")
        let actionsParent = NSMenuItem(title: "동작 예시", action: nil, keyEquivalent: "")
        actionsParent.submenu = actionsMenu
        menu.addItem(actionsParent)
        idleItem = addItem(character.idleActionTitle, action: #selector(playNow), in: actionsMenu)
        _ = addItem("커서 잡기 (잠시 멈춰 주세요)", action: #selector(catchCursorNow), in: actionsMenu)
        _ = addItem("걷기", action: #selector(walkNow), in: actionsMenu)
        _ = addItem("뛰기", action: #selector(runNow), in: actionsMenu)
        _ = addItem("위로 점프", action: #selector(jumpNow), in: actionsMenu)
        _ = addItem("아래로 내려가기", action: #selector(dropNow), in: actionsMenu)
        _ = addItem("방향 바꾸기", action: #selector(turnAround), in: actionsMenu)
        keyboardItem = addItem("키보드 조종 켜기", action: #selector(toggleKeyboardMode))
        pauseItem = addItem("일시정지", action: #selector(togglePause))
        hideItem = addItem("\(character.displayName) 숨기기", action: #selector(toggleHidden))
        menu.addItem(.separator())
        let sizeMenu = NSMenu(title: "크기 배율")
        let sizeParent = NSMenuItem(title: "크기 배율", action: nil, keyEquivalent: "")
        sizeParent.submenu = sizeMenu
        menu.addItem(sizeParent)
        for scale in PetSizing.scales {
            let label = String(format: "%g배", scale) + (scale == 1 ? " (기본)" : "")
            let item = NSMenuItem(title: label, action: #selector(changeSize(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(scale * 100)
            sizeMenu.addItem(item)
            sizeItems.append(item)
        }
        _ = addItem("위치 초기화", action: #selector(resetPosition))
        menu.addItem(.separator())
        _ = addItem("모두 종료", action: #selector(quit), key: "q")
        updateMenu()
    }

    private func updateMenu() {
        titleItem.title = "바탕화면 친구 · \(characterName)"
        idleItem.title = currentCustom == nil ? character.idleActionTitle : "지금 대기 동작 보기"
        pauseItem.title = paused ? "다시 움직이기" : "일시정지"
        hideItem.title = "\(characterName) \(hidden ? "보이기" : "숨기기")"
        for (choice, item) in characterItems { item.state = currentCustom == nil && choice == character ? .on : .off }
        for (id, item) in customItems { item.state = id == selectedCharacterID ? .on : .off }
        keyboardItem.title = keyboardMode ? "키보드 조종 끄기 (Esc)" : "키보드 조종 켜기"
        keyboardItem.state = keyboardMode ? .on : .off
        for item in sizeItems { item.state = Double(item.tag) / 100 == sizing.scale ? .on : .off }
    }

    @objc private func changeCharacter(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let choice = PetCharacter(rawValue: name) else { return }
        setCharacter(choice)
    }

    static func makeMainMenu() {
        let main = NSMenu()
        let application = NSMenuItem(); application.submenu = NSMenu()
        application.submenu?.addItem(withTitle: "바탕화면 친구 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(application)
        let edit = NSMenuItem(title: "편집", action: nil, keyEquivalent: "")
        let commands = NSMenu(title: "편집")
        for (title, selector, key) in [("실행 취소", "undo:", "z"), ("잘라내기", "cut:", "x"), ("복사", "copy:", "c"), ("붙여넣기", "paste:", "v"), ("모두 선택", "selectAll:", "a")] {
            commands.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        edit.submenu = commands; main.addItem(edit)
        NSApp.mainMenu = main
    }

    private func setCharacter(_ choice: PetCharacter) {
        guard choice != character || currentCustom != nil, let selected = atlases[choice] else { return }
        applyCharacter(selected, base: choice, custom: nil)
    }

    private func applyCharacter(_ selected: SpriteAtlas, base choice: PetCharacter, custom: CustomCharacter?) {
        stopActivity()
        cancelHop()
        let feet = physics.feet
        character = choice
        currentCustom = custom
        atlas = selected
        playback.rest()
        cursorGaze = CursorGaze()
        walkUntil = 0
        nextCursorPlay = ProcessInfo.processInfo.systemUptime + Self.cursorPlayInterval
        dogView.sprite = atlas.resting
        dogView.mirrored = false
        dogView.renderOffset = .zero
        panel.setFrame(CGRect(x: feet.x - windowSize.width / 2, y: feet.y - 6,
                              width: windowSize.width, height: windowSize.height), display: true)
        clampPosition()
        physics.wrapHalfWidth = dogHeight * atlas.windowWidthRatio / 2
        physics.teleport(to: CGPoint(x: panel.frame.midX, y: panel.frame.minY + 6))
        refreshScene()
        dogView.needsDisplay = true
        savePosition()
        updateMenu()
        collection?.changed()
        restartActivity()
        if keyboardMode { takeKeyboardFocus() }
    }

    private func rebuildCustomMenu() {
        for item in customItems.values { characterMenu.removeItem(item) }
        customItems.removeAll()
        if let customSeparator { characterMenu.removeItem(customSeparator) }
        customSeparator = nil
        if !customProfiles.isEmpty {
            let separator = NSMenuItem.separator()
            characterMenu.addItem(separator)
            customSeparator = separator
        }
        for profile in customProfiles {
            let item = NSMenuItem(title: profile.name, action: #selector(changeCustomCharacter(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = profile.id
            characterMenu.addItem(item); customItems[profile.id] = item
        }
    }

    @objc private func changeCustomCharacter(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let profile = customProfiles.first(where: { $0.id == id }) else { return }
        do {
            let selected = try customAtlases[id] ?? SpriteAtlas(custom: profile)
            customAtlases[id] = selected
            applyCharacter(selected, base: profile.base, custom: profile)
        } catch {
            let alert = NSAlert(); alert.messageText = "캐릭터를 불러오지 못했습니다."
            alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }

    @objc private func createCharacter() { collection?.openCreator() }
    @objc private func manageCharacters() { collection?.openLibrary() }
    @objc private func addCopy() { collection?.addCharacter(selectedCharacterID, scale: sizing.scale, baseHeight: Double(sizing.baseHeight)) }
    @objc private func removeCopy() { collection?.remove(self) }

    @objc private func toggleKeyboardMode() { setKeyboardMode(!keyboardMode) }

    private func setKeyboardMode(_ enabled: Bool) {
        stopActivity()
        cancelHop()
        controls.reset()
        physics.horizontalVelocity = 0
        landingWalkVelocity = 0
        if enabled, let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = front
        }
        keyboardMode = enabled
        panel.keyboardEnabled = enabled
        if enabled {
            paused = false
            hidden = false
            dogView.toolTip = "A/D 이동 · W/스페이스 점프 · S 내려가기 · Shift 달리기 · Esc 자동 모드"
            takeKeyboardFocus()
        } else {
            panel.resignKey()
            dogView.keyboardFocused = false
            dogView.needsDisplay = true
            dogView.toolTip = "드래그해서 이동 · 우클릭으로 메뉴 열기"
            if NSApp.isActive { previousApplication?.activate(options: []) }
            previousApplication = nil
        }
        updateMenu()
        restartActivity()
    }

    private func takeKeyboardFocus() {
        guard keyboardMode, !closed, collection?.uiPaused != true else { return }
        controls.reset()
        controls.running = NSEvent.modifierFlags.contains(.shift)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(dogView)
        dogView.keyboardFocused = panel.isKeyWindow
        dogView.needsDisplay = true
        // Activation completes on the next AppKit turn, particularly from a status menu.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.keyboardMode, !self.closed, self.collection?.uiPaused != true else { return }
            self.panel.makeKeyAndOrderFront(nil)
            self.panel.makeFirstResponder(self.dogView)
            self.dogView.keyboardFocused = self.panel.isKeyWindow
            self.dogView.needsDisplay = true
        }
    }

    private func resetControlKeys() {
        controls.reset()
        if keyboardMode && physics != nil {
            physics.horizontalVelocity = 0
            landingWalkVelocity = 0
        }
    }

    private func handleControlKey(_ event: NSEvent) -> Bool {
        guard keyboardMode, panel.isKeyWindow else { return false }
        let shortcutModifiers: NSEvent.ModifierFlags = [.command, .option, .control]
        if event.type == .flagsChanged {
            if !event.modifierFlags.intersection(shortcutModifiers).isEmpty { resetControlKeys() }
            controls.running = event.modifierFlags.contains(.shift)
            return true
        }
        guard KeyboardControls.Key(rawValue: event.keyCode) != nil else { return false }
        if event.type == .keyUp {
            controls.keyUp(code: event.keyCode)
            return true
        }
        guard event.type == .keyDown, event.modifierFlags.intersection(shortcutModifiers).isEmpty else { return false }
        if event.keyCode == KeyboardControls.Key.escape.rawValue {
            setKeyboardMode(false)
            return true
        }
        guard isActive else { return true }
        controls.running = event.modifierFlags.contains(.shift)
        let action = controls.keyDown(code: event.keyCode, isRepeat: event.isARepeat)
        if physics.grounded && hop == nil {
            switch action {
            case .jump:
                gait = controls.gait
                physics.horizontalVelocity = controls.horizontalAxis * gait.speed
                beginHop(.inPlace(max(220, dogHeight * 2.5)))
            case .down: beginHop(.down)
            case .exit: setKeyboardMode(false)
            case nil: break
            }
        }
        display()
        return true
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard dogView != nil else { return }
        dogView.keyboardFocused = keyboardMode
        dogView.needsDisplay = true
    }

    func windowDidResignKey(_ notification: Notification) {
        resetControlKeys()
        guard dogView != nil else { return }
        dogView.keyboardFocused = false
        dogView.needsDisplay = true
    }

    func applicationDidResignActive(_ notification: Notification) { resetControlKeys() }

    private func display() {
        guard dogView != nil else { return }
        let sprite: DogSprite
        let mirrored: Bool
        let attachment: CursorAttachment?
        if let cursorPlay {
            sprite = (cursorPlay.rolling ? atlas.cursorRoll : atlas.cursorJump)[cursorPlay.frameIndex]
            mirrored = cursorPlay.mirrored
            attachment = cursorPlay.hasCursor ? atlas.cursorAttachment(rolling: cursorPlay.rolling, frame: cursorPlay.frameIndex) : nil
        } else if let hop, physics != nil && !dragging {
            sprite = atlas.hopSprite(for: hop, verticalVelocity: physics.verticalVelocity)
            mirrored = physics.facesLeft
            attachment = nil
        } else if physics != nil && physics.moving && isActive {
            (sprite, mirrored) = atlas.movementSprite(gait: gait, facingLeft: physics.facesLeft,
                                                     at: ProcessInfo.processInfo.systemUptime)
            attachment = nil
        } else {
            if physics != nil && physics.grounded && !physics.moving && !dragging {
                cursorGaze.update(cursor: NSEvent.mouseLocation,
                                  head: CGPoint(x: physics.feet.x, y: physics.feet.y + dogHeight * 0.68),
                                  height: dogHeight)
                sprite = playback.frameIndex.map { atlas.idle[$0] } ?? atlas.gazing[cursorGaze.direction.rawValue]
            } else {
                sprite = playback.frameIndex.map { atlas.idle[$0] } ?? atlas.resting
            }
            mirrored = false
            attachment = nil
        }
        if dogView.sprite.image !== sprite.image || dogView.mirrored != mirrored || dogView.cursorAttachment != attachment {
            dogView.sprite = sprite
            dogView.mirrored = mirrored
            dogView.cursorAttachment = attachment
            dogView.needsDisplay = true
        }
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard isActive, physics != nil, !physics.moving, hop == nil, cursorPlay == nil else { return }
        let next = Timer(timeInterval: playback.nextDelay, target: self,
                         selector: #selector(tick), userInfo: nil, repeats: false)
        next.tolerance = playback.frameIndex == nil ? 0.2 : 0.01
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    @objc private func tick() {
        playback.advance()
        display()
        schedule()
    }
    @objc private func playNow() {
        cancelHop()
        stopActivity()
        paused = false
        hidden = false
        panel.orderFrontRegardless()
        physics.horizontalVelocity = 0
        walkUntil = 0
        playback.playNow()
        display()
        updateMenu()
        restartActivity()
    }
    @objc private func togglePause() {
        stopActivity()
        paused.toggle()
        playback.rest()
        display()
        updateMenu()
        restartActivity()
    }
    @objc private func toggleHidden() {
        stopActivity()
        hidden.toggle()
        if hidden { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        playback.rest()
        display()
        updateMenu()
        restartActivity()
    }
    @objc private func changeSize(_ sender: NSMenuItem) {
        cancelHop()
        stopActivity()
        sizing.scale = Double(sender.tag) / 100
        dogView.dogHeight = dogHeight
        // Keep the dog's head center and feet in the same desktop location.
        let center = panel.frame.midX, bottom = panel.frame.minY
        panel.setFrame(CGRect(x: center - windowSize.width / 2, y: bottom,
                              width: windowSize.width, height: windowSize.height), display: true)
        clampPosition()
        physics.bodyHeight = dogHeight
        physics.wrapHalfWidth = dogHeight * atlas.windowWidthRatio / 2
        physics.teleport(to: CGPoint(x: panel.frame.midX, y: panel.frame.minY + 6))
        refreshScene()
        dogView.needsDisplay = true
        savePosition()
        updateMenu()
        restartActivity()
    }
    @objc private func resetPosition() {
        cancelHop()
        stopActivity()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let area = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(x: area.maxX - panel.frame.width - 48, y: area.minY + 18))
        clampPosition()
        if physics != nil {
            physics.area = area
            physics.teleport(to: CGPoint(x: panel.frame.midX, y: area.minY))
            refreshScene()
        }
        savePosition()
        restartActivity()
    }
    private var currentScreen: NSScreen? {
        let screens = NSScreen.screens
        return screens.max(by: {
            let a = $0.visibleFrame.intersection(panel.frame)
            let b = $1.visibleFrame.intersection(panel.frame)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        })
    }
    private func clampPosition() {
        guard let screen = currentScreen else { return }
        panel.setFrameOrigin(clampedOrigin(panel.frame.origin, in: screen.visibleFrame))
    }
    private func clampedOrigin(_ point: CGPoint, in area: CGRect) -> CGPoint {
        CGPoint(x: max(area.minX, min(point.x, max(area.minX, area.maxX - windowSize.width))),
                y: max(area.minY - 6, min(point.y, max(area.minY - 6, area.maxY - windowSize.height))))
    }
    private func savePosition() { collection?.save() }
    private var isActive: Bool { !closed && !paused && !hidden && !dragging && !menuTracking && !sleeping && collection?.uiPaused != true }

    private func stopActivity() {
        cancelCursorPlay()
        cursorRequestUntil = 0
        cursorStillSince = ProcessInfo.processInfo.systemUptime
        resetControlKeys()
        timer?.invalidate(); timer = nil
        roamingTimer?.invalidate(); roamingTimer = nil
        movementTimer?.invalidate(); movementTimer = nil
        playback.rest()
        if dogView != nil { display() }
    }

    private func restartActivity() {
        timer?.invalidate(); timer = nil
        roamingTimer?.invalidate(); roamingTimer = nil
        movementTimer?.invalidate(); movementTimer = nil
        guard isActive, physics != nil else { display(); return }
        lastPhysicsTime = ProcessInfo.processInfo.systemUptime
        nextSceneRefresh = 0
        let movement = Timer(timeInterval: 1.0 / 30, target: self,
                             selector: #selector(physicsTick), userInfo: nil, repeats: true)
        movement.tolerance = 0.003
        RunLoop.main.add(movement, forMode: .common)
        movementTimer = movement
        if !keyboardMode {
            let remainingWalk = max(0, walkUntil - lastPhysicsTime)
            scheduleSurfaceAction(after: remainingWalk > 0 ? remainingWalk + RoamingRhythm().rest : RoamingRhythm.resumeDelay)
        }
        schedule()
        display()
    }

    private func scheduleSurfaceAction(after delay: TimeInterval) {
        roamingTimer?.invalidate(); roamingTimer = nil
        guard isActive, !keyboardMode else { return }
        let next = Timer(timeInterval: delay, target: self, selector: #selector(chooseSurfaceAction), userInfo: nil, repeats: false)
        next.tolerance = 0.05
        RunLoop.main.add(next, forMode: .common)
        roamingTimer = next
    }

    private func refreshScene() {
        guard physics != nil else { return }
        let ledges = WindowLedges.make(from: WindowLedges.read(), area: physics.area)
        physics.updateLedges(ledges)
    }

    private func attemptUpwardJump() -> Bool {
        if !isClimbing { climbedWindows.removeAll() }
        switch ClimbPlanner.nextStep(for: physics, completedWindows: climbedWindows) {
        case .jump(let ledge):
            isClimbing = true
            approachingClimb = false
            preferDescending = false
            beginHop(.onto(ledge))
            return true
        case .approach(let x):
            isClimbing = true
            approachingClimb = true
            preferDescending = false
            gait = .walking
            physics.horizontalVelocity = x < physics.feet.x ? -gait.speed : gait.speed
            walkUntil = ProcessInfo.processInfo.systemUptime + RoamingRhythm.movementDuration
            return true
        case .finished:
            isClimbing = false
            approachingClimb = false
            return false
        }
    }

    private func beginHop(_ action: HopAction) {
        guard physics != nil, physics.grounded, hop == nil, cursorPlay == nil else { return }
        switch action {
        case .down:
            guard physics.supportID != 0 else { return }
        case .onto, .inPlace:
            guard physics.ceiling - physics.feet.y > 4 else { return }
        }
        physics.horizontalVelocity = 0
        pendingHop = action
        hop = HopPlayback(kind: action.kind)
        landingWalkVelocity = 0
        timer?.invalidate(); timer = nil
        playback.rest()
        display()
    }

    private func launchPendingHop() {
        guard let pendingHop else { cancelHop(); return }
        switch pendingHop {
        case .onto(let target):
            // Refresh the chosen rim after the preparation pose, since its window may move.
            let current = physics.ledges.filter {
                $0.id == target.id && $0.maxX - $0.minX > physics.footHalfWidth * 2
            }.min { abs($0.minX - target.minX) < abs($1.minX - target.minX) }
            if let current { _ = physics.jump(to: current) }
        case .inPlace(let height): physics.jump(height: height)
        case .down: physics.dropDown()
        }
        self.pendingHop = nil
        if physics.grounded { cancelHop() } else { hop?.launched() }
    }

    private func cancelHop() {
        hop = nil
        pendingHop = nil
        landingWalkVelocity = 0
        isClimbing = false
        approachingClimb = false
        climbedWindows.removeAll()
    }

    private func updateHopContact() {
        let previousPhase = hop?.phase
        hop?.observe(grounded: physics.grounded, landingSoon: physics.willLandSoon())
        if previousPhase != .landing && hop?.phase == .landing {
            if isClimbing, let support = physics.support, support.edge == .upper {
                climbedWindows.insert(support.id / 2)
            }
            landingWalkVelocity = (isClimbing || keyboardMode) ? 0 : physics.horizontalVelocity
            physics.horizontalVelocity = 0
        }
    }

    @objc private func catchCursorNow() {
        if keyboardMode { setKeyboardMode(false) }
        cancelCursorPlay()
        cancelHop()
        paused = false
        hidden = false
        panel.orderFrontRegardless()
        physics.horizontalVelocity = 0
        let now = ProcessInfo.processInfo.systemUptime
        lastCursor = NSEvent.mouseLocation
        cursorStillSince = now
        cursorRequestUntil = now + 15
        updateMenu()
        restartActivity()
    }

    @discardableResult
    private func beginCursorPlay(at cursor: CGPoint, automatic: Bool) -> Bool {
        guard isActive, !keyboardMode, physics.grounded, hop == nil, cursorPlay == nil,
              collection?.canCatchCursor(self) != false, NSEvent.pressedMouseButtons == 0 else { return false }
        let mirrored = cursor.x < physics.feet.x
        let grip = atlas.cursorAttachment(rolling: false, frame: 4).offset(in: atlas.cursorJump[4], height: dogHeight, mirrored: mirrored)
        let destination = CGPoint(x: cursor.x - grip.x, y: cursor.y - grip.y)
        guard physics.area.contains(cursor), destination.y >= physics.area.minY,
              destination.y <= physics.ceiling, physics.ceiling - physics.feet.y > 8 else { return false }
        if automatic {
            guard abs(destination.x - physics.feet.x) <= 420,
                  abs(destination.y - physics.feet.y) <= 360 else { return false }
        }
        cancelHop()
        physics.horizontalVelocity = 0
        walkUntil = 0
        timer?.invalidate(); timer = nil
        playback.rest()
        cursorRequestUntil = 0
        cursorPlayBegan = ProcessInfo.processInfo.systemUptime
        nextCursorPlay = cursorPlayBegan + Self.cursorPlayInterval
        collection?.cursorOwner = self
        cursorPlay = CursorPlay(start: physics.feet, cursor: cursor, gripOffset: grip, ceiling: physics.ceiling)
        display()
        return true
    }

    private func positionDog(at feet: CGPoint) {
        let origin = CGPoint(x: feet.x - panel.frame.width / 2, y: feet.y - 6)
        if abs(origin.x - panel.frame.minX) > 0.01 || abs(origin.y - panel.frame.minY) > 0.01 {
            panel.setFrameOrigin(origin)
        }
        // AppKit rounds window origins; preserve the exact paw/cursor contact inside the view.
        let offset = CGPoint(x: feet.x - panel.frame.midX, y: feet.y - panel.frame.minY - 6)
        if dogView.renderOffset != offset {
            dogView.renderOffset = offset
            dogView.needsDisplay = true
        }
    }

    private func cancelCursorPlay() {
        heldCursor.release()
        if let play = cursorPlay, !play.usesPhysics, physics != nil {
            // Resume normal gravity from the visible position, even when interrupted mid-flight.
            physics.teleport(to: play.feet)
            positionDog(at: physics.feet)
        }
        cursorPlay = nil
        if collection?.cursorOwner === self { collection?.cursorOwner = nil }
        dogView?.cursorAttachment = nil
        dogView?.needsDisplay = true
    }

    /// Returns true while this tick was consumed by the cursor trick.
    @discardableResult
    private func advanceCursorPlay(by delta: TimeInterval, cursor: CGPoint, buttons: Int) -> Bool {
        guard var play = cursorPlay else { return false }
        if play.interrupted(by: cursor, mouseButtons: buttons) ||
            ProcessInfo.processInfo.systemUptime - cursorPlayBegan > 10 {
            cancelCursorPlay()
            return false
        }
        let usedPhysics = play.usesPhysics
        if usedPhysics {
            physics.horizontalVelocity = 0
            physics.advance(by: delta)
        }
        let previousPhase = play.phase
        play.advance(by: delta, grounded: physics.grounded)
        if previousPhase != .holding && play.phase == .holding && !heldCursor.begin() {
            cursorPlay = play
            cancelCursorPlay()
            return false
        }
        if play.usesPhysics && !usedPhysics {
            physics.teleport(to: play.destination)
            refreshScene()
            physics.advance(by: delta)
        }
        cursorPlay = play
        positionDog(at: play.usesPhysics ? physics.feet : play.feet)
        if play.phase == .finished {
            cancelCursorPlay()
            savePosition()
        }
        display()
        return true
    }

    @objc private func chooseSurfaceAction() {
        var nextDelay = RoamingRhythm.retryDelay
        defer { scheduleSurfaceAction(after: nextDelay) }
        guard isActive, !keyboardMode, physics.grounded, hop == nil, cursorPlay == nil, cursorRequestUntil == 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if !isClimbing, now >= nextCursorPlay, now - cursorStillSince >= 2.5 {
            nextCursorPlay = now + Self.cursorPlayInterval
            if beginCursorPlay(at: NSEvent.mouseLocation, automatic: true) { return }
        }
        refreshScene()
        timer?.invalidate(); timer = nil
        playback.rest()
        let rhythm = RoamingRhythm()
        walkUntil = now + rhythm.movement
        if isClimbing {
            if !attemptUpwardJump() {
                // Rest on the highest reached window before choosing descent or roaming.
                preferDescending = true
                physics.horizontalVelocity = 0
                walkUntil = 0
                schedule()
                nextDelay = rhythm.rest
            }
            display()
            return
        }
        nextDelay = rhythm.nextDelay
        if rhythm.restOnly {
            physics.horizontalVelocity = 0
            walkUntil = now
            schedule(); display()
            return
        }
        actionCount += 1
        if actionCount % 3 == 1 {
            gait = GroundGait.randomForRoaming()
            physics.horizontalVelocity = Bool.random() ? gait.speed : -gait.speed
        } else if preferDescending && physics.support?.edge == .upper {
            physics.horizontalVelocity = 0
            beginHop(.down)
            preferDescending = false
        } else if !attemptUpwardJump() {
            gait = GroundGait.randomForRoaming()
            physics.horizontalVelocity = Bool.random() ? gait.speed : -gait.speed
            if physics.support?.edge == .lower && preferDescending {
                beginHop(.down)
                preferDescending = false
            }
        }
        if isClimbing { nextDelay = RoamingRhythm.retryDelay }
        display()
    }

    @objc private func physicsTick() {
        guard isActive, physics != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now >= nextSceneRefresh {
            refreshScene()
            nextSceneRefresh = now + 0.2
        }
        let delta = min(0.1, max(0, now - lastPhysicsTime))
        let cursor = NSEvent.mouseLocation
        if hypot(cursor.x - lastCursor.x, cursor.y - lastCursor.y) > 1 || NSEvent.pressedMouseButtons != 0 {
            lastCursor = cursor
            cursorStillSince = now
        }
        if now > cursorRequestUntil { cursorRequestUntil = 0 }
        if cursorRequestUntil > now && now - cursorStillSince >= 1 {
            _ = beginCursorPlay(at: cursor, automatic: false)
        }
        if advanceCursorPlay(by: delta, cursor: cursor, buttons: NSEvent.pressedMouseButtons) {
            lastPhysicsTime = now
            return
        }
        let wasMoving = physics.moving
        if !keyboardMode && approachingClimb && physics.grounded && hop == nil {
            _ = attemptUpwardJump()
        }
        hop?.advanceClock(by: delta)
        if hop?.phase == .preparing && !physics.grounded {
            pendingHop = nil
            hop = HopPlayback(kind: .downward, alreadyAirborne: true)
        }
        if hop?.readyToLaunch == true { launchPendingHop() }
        if hop?.finished == true {
            hop = nil
            if physics.grounded && now < walkUntil { physics.horizontalVelocity = landingWalkVelocity }
            landingWalkVelocity = 0
        }
        if hop?.holdsHorizontalMotion == true { physics.horizontalVelocity = 0 }
        if keyboardMode {
            gait = controls.gait
            if panel.isKeyWindow && hop?.holdsHorizontalMotion != true {
                physics.horizontalVelocity = controls.horizontalAxis * gait.speed
            } else {
                physics.horizontalVelocity = 0
            }
        } else if now >= walkUntil && physics.grounded { physics.horizontalVelocity = 0 }
        if hop == nil && !physics.grounded {
            hop = HopPlayback(kind: .downward, alreadyAirborne: true)
        }
        // Predict contact before integration so the third pose appears before the paws touch.
        updateHopContact()
        physics.advance(by: delta)
        if hop == nil && !physics.grounded {
            hop = HopPlayback(kind: .downward, alreadyAirborne: true)
        }
        updateHopContact()
        if hop?.phase == .landing && !physics.grounded {
            hop = HopPlayback(kind: .downward, alreadyAirborne: true)
        }
        lastPhysicsTime = now
        positionDog(at: physics.feet)
        if physics.moving || hop != nil {
            timer?.invalidate(); timer = nil
            playback.rest()
        } else if timer == nil {
            playback.rest()
            schedule()
        }
        if wasMoving && !physics.moving { savePosition() }
        display()
    }

    @objc private func jumpNow() {
        paused = false
        hidden = false
        panel.orderFrontRegardless()
        refreshScene()
        if physics.grounded && hop == nil && !attemptUpwardJump() { beginHop(.inPlace(dogHeight * 1.2)) }
        walkUntil = ProcessInfo.processInfo.systemUptime + 4
        playback.rest()
        updateMenu()
        restartActivity()
    }
    @objc private func dropNow() {
        paused = false
        if hop == nil {
            isClimbing = false
            approachingClimb = false
            beginHop(.down)
        }
        playback.rest()
        updateMenu()
        restartActivity()
    }
    @objc private func turnAround() {
        paused = false
        cancelHop()
        physics.horizontalVelocity = physics.facesLeft ? gait.speed : -gait.speed
        walkUntil = ProcessInfo.processInfo.systemUptime + 7
        playback.rest()
        updateMenu()
        restartActivity()
    }

    private func moveNow(_ selected: GroundGait) {
        if hop?.phase == .preparing { cancelHop() }
        isClimbing = false
        approachingClimb = false
        paused = false
        hidden = false
        panel.orderFrontRegardless()
        gait = selected
        let speed = physics.facesLeft ? -gait.speed : gait.speed
        physics.horizontalVelocity = speed
        if hop?.phase == .landing { landingWalkVelocity = speed }
        walkUntil = ProcessInfo.processInfo.systemUptime + 7
        playback.rest()
        updateMenu()
        restartActivity()
    }
    @objc private func walkNow() { moveNow(.walking) }
    @objc private func runNow() { moveNow(.running) }

    func menuWillOpen(_ menu: NSMenu) { menuTracking = true; stopActivity(); collection?.menuWillOpen(menu) }
    func menuDidClose(_ menu: NSMenu) {
        menuTracking = false
        collection?.menuDidClose(menu)
        restartActivity()
        if keyboardMode { takeKeyboardFocus() }
    }
    @objc private func screensChanged() {
        cancelHop()
        stopActivity()
        clampPosition()
        if let screen = currentScreen {
            physics.area = screen.visibleFrame
            physics.teleport(to: CGPoint(x: panel.frame.midX, y: panel.frame.minY + 6))
            refreshScene()
        }
        savePosition()
        restartActivity()
    }
    @objc private func willSleep() { sleeping = true; stopActivity() }
    @objc private func didWake() { sleeping = false; restartActivity() }
    @objc private func quit() { NSApp.terminate(nil) }
    private func verify() throws {
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw AssetError.invalid(message) }
        }
        try check(atlas.idle.count == 8, "대기 프레임 개수")
        try check(atlas.walking.count == 8, "걷기 프레임 개수")
        try check(atlas.running.count == 8, "달리기 프레임 개수")
        try check(atlas.gazing.count == 3, "커서 시선 세 방향")
        try check(atlas.cursorJump.count == 8 && atlas.cursorRoll.count == 8, "커서 잡기·구르기 각 8프레임")
        try check(atlas.jumping.count == 4 && atlas.descending.count == 4, "도약·하강 각 4프레임")
        var player = IdlePlayback()
        try check(player.frameIndex == nil, "기본 정지 상태")
        for index in 0..<8 {
            player.advance()
            try check(player.frameIndex == index, "프레임 순서 \(index)")
            try check(player.nextDelay == IdlePlayback.frameDurations[index], "프레임 시간")
        }
        player.advance()
        try check(player.frameIndex == nil, "재생 후 기본 포즈 복귀")
        try check((3.5...6.5).contains(player.nextDelay), "정지 상태 유지 시간")
        player.playNow()
        try check(player.frameIndex == 0, "즉시 재생")
        player.rest()
        try check(player.frameIndex == nil, "정지/복귀")
        for sprite in [atlas.resting] + atlas.idle + atlas.walking {
            let canvas = CGRect(x: 0, y: 0, width: 212, height: 172)
            let rect = sprite.drawingRect(in: canvas, height: 160)
            try check(canvas.contains(rect), "강아지가 창 밖으로 잘렸습니다.")
            try check(rect.minY == 6 && rect.height > 0 && rect.height <= 160.001, "발 위치/크기 정렬")
        }
        for sprite in atlas.jumping + atlas.descending {
            let canvas = CGRect(x: 0, y: 0, width: 212, height: 172)
            let rect = sprite.drawingRect(in: canvas, height: 160)
            try check(canvas.contains(rect), "도약 프레임이 창 밖으로 잘렸습니다.")
            try check(rect.minY == 6 && rect.height > 0 && rect.height <= 160.001, "도약 발 위치·배율")
        }
        let hopCanvas = CGRect(x: 0, y: 0, width: 212, height: 172)
        try check(atlas.jumping[0].drawingRect(in: hopCanvas, height: 160).height <
                  atlas.jumping[1].drawingRect(in: hopCanvas, height: 160).height,
                  "준비 자세의 웅크림 유지")
        let migrated = PetSizing(savedBase: 0, savedScale: 0, legacyHeight: 120)
        try check(migrated.height == 60 && migrated.scale == 1, "현재 크기를 절반으로 변경")
        let relaunched = PetSizing(savedBase: Double(migrated.baseHeight), savedScale: 1, legacyHeight: 120)
        try check(relaunched.height == 60, "재실행해도 크기를 다시 절반으로 줄이지 않음")
        let doubled = PetSizing(savedBase: 60, savedScale: 2, legacyHeight: 120)
        try check(doubled.height == 120, "저장된 2배 크기 복원")
        for scale in PetSizing.scales {
            let height = CGFloat(60 * scale)
            let canvas = CGRect(x: 0, y: 0, width: height * atlas.windowWidthRatio + 12, height: height + 12)
            for sprite in atlas.allSprites {
                try check(canvas.contains(sprite.drawingRect(in: canvas, height: height)), "배율 변경 후 이미지 잘림")
            }
        }
        var gaze = CursorGaze()
        let head = CGPoint(x: -400, y: 300)
        gaze.update(cursor: CGPoint(x: -600, y: 500), head: head, height: 60)
        try check(gaze.direction == .left, "커서가 왼쪽 위")
        gaze.update(cursor: CGPoint(x: -400, y: 900), head: head, height: 60)
        try check(gaze.direction == .up, "커서가 정면 위")
        gaze.update(cursor: CGPoint(x: -200, y: 500), head: head, height: 60)
        try check(gaze.direction == .right, "커서가 오른쪽 위")
        gaze.update(cursor: CGPoint(x: -325, y: 500), head: head, height: 60)
        try check(gaze.direction == .right, "경계 근처 시선 유지")
        gaze.update(cursor: CGPoint(x: -400, y: 300), head: head, height: 60)
        try check(gaze.direction == .up, "커서가 얼굴 위에 있으면 중앙")
        let gaitArea = CGRect(x: 0, y: 0, width: 1200, height: 900)
        var walking = PetPhysics(feet: CGPoint(x: 200, y: 0), area: gaitArea, bodyHeight: 60)
        var running = walking
        walking.horizontalVelocity = GroundGait.walking.speed
        running.horizontalVelocity = GroundGait.running.speed
        for _ in 0..<60 { walking.advance(by: 1.0 / 60); running.advance(by: 1.0 / 60) }
        try check(running.feet.x - 200 > walking.feet.x - 200 && running.grounded && walking.grounded,
                  "지면에서 달리기가 걷기보다 빠름")
        for gait in GroundGait.allCases {
            let seen = Set((0..<100).map { gait.frameIndex(at: Double($0) / 100) })
            try check(seen == Set(0..<8), "걷기·달리기 8프레임 순환")
        }
        try HopChecks.run()
        try PhysicsChecks.run()
        try ClimbChecks.run()
        try KeyboardChecks.run()
        try RoamingRhythm.checkIndependentTimelines()
        print("PASS: 공유 시간축에서 캐릭터별 무작위 이동·휴식·서로 다른 행동 시각")
        for choice in PetCharacter.allCases {
            try CharacterChecks.run(atlas: atlases[choice]!)
            try CursorPlayChecks.run(atlas: atlases[choice]!)
        }
        if CommandLine.arguments.contains("--cursor-capability-check") {
            try check(SystemCursorVisibility.backgroundHidingAvailable, "이 macOS에서 백그라운드 커서 표시 제어를 사용할 수 없습니다.")
            print("PASS: 백그라운드 커서 표시 제어 연결 (포커스·커서 위치·커서 표시 상태 변경 없음)")
        }
        if CommandLine.arguments.contains("--keyboard-window-check") {
            try verifyKeyboardWindow()
        }
        if CommandLine.arguments.contains("--cursor-window-check") {
            try verifyCursorWindow()
        }
        if CommandLine.arguments.contains("--character-window-check") {
            try verifyCharacterWindow()
        }
        if CommandLine.arguments.contains("--creator-window-check") {
            let root = Bundle.main.resourceURL!.appendingPathComponent("img")
            try CustomCharacterChecks.run(imagesRoot: root) { profile, customAtlas in
                if self.panel == nil { self.makeMenu(); self.makePanel() }
                let original = self.character
                self.customProfiles.append(profile)
                self.customAtlases[profile.id] = customAtlas
                self.rebuildCustomMenu()
                self.changeCustomCharacter(self.customItems[profile.id]!)
                try check(self.selectedCharacterID == profile.id && self.characterName == profile.name && self.customItems[profile.id]?.state == .on, "사용자 캐릭터 메뉴·선택 적용")
                try check(self.characterItems.values.allSatisfy { $0.state == .off }, "기본 캐릭터 체크 해제")
                self.setCharacter(original)
                self.customProfiles.removeAll { $0.id == profile.id }
                self.customAtlases.removeValue(forKey: profile.id)
                self.rebuildCustomMenu()
                self.stopActivity()
            }
        }
        if CommandLine.arguments.contains("--scene-check") {
            let windows = WindowLedges.read()
            let area = NSScreen.screens.first?.visibleFrame ?? .zero
            let ledges = WindowLedges.make(from: windows, area: area)
            print("현재 화면 감지: 창 \(windows.count)개, 노출된 위·아래 테두리 \(ledges.count)개")
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--preview"),
           CommandLine.arguments.indices.contains(flag + 1) {
            try renderPreview(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--hop-preview"),
           CommandLine.arguments.indices.contains(flag + 1) {
            try renderHopPreview(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--run-preview"),
           CommandLine.arguments.indices.contains(flag + 1) {
            try renderRunningPreview(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--gaze-preview"),
           CommandLine.arguments.indices.contains(flag + 1) {
            let labels = ["왼쪽 위", "정면 위", "오른쪽 위"]
            let entries = atlas.gazing.enumerated().map { ($0.element, labels[$0.offset], false) }
            try renderGrid(entries, to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--cursor-preview"),
           CommandLine.arguments.indices.contains(flag + 1) {
            let entries = (atlas.cursorJump + atlas.cursorRoll).enumerated().map { index, sprite in
                (sprite, "\(index < 8 ? "잡기" : "구르기") \(index % 8 + 1)", false)
            }
            try renderGrid(entries, to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]), cursorPreview: true)
        }
        print("PASS: 강아지·보노보노 전 동작·배율, 좌우 걷기, 도약 8프레임, 커서 잡기·구르기·복구, WASD, 순차 등반·중력")
    }

    private func verifyCharacterWindow() throws {
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw AssetError.invalid("캐릭터 전환 검사: \(message)") }
        }
        if panel == nil { makeMenu(); makePanel() }
        let original = character
        let originalCursor = heldCursor
        var hides = 0, shows = 0
        heldCursor = HeldCursor(hide: { hides += 1; return true }, show: { shows += 1 })
        defer {
            cancelCursorPlay()
            setCharacter(original)
            stopActivity()
            heldCursor = originalCursor
        }
        for choice: PetCharacter in [.puppy, .bonobono, .puppy, .bonobono] {
            physics.teleport(to: CGPoint(x: physics.area.midX, y: physics.area.minY))
            physics.updateLedges([])
            physics.advance(by: 1.0 / 120)
            positionDog(at: physics.feet)
            let feet = physics.feet
            changeCharacter(characterItems[choice]!)
            try check(character == choice && atlas.character == choice, "선택한 캐릭터 적용")
            try check(abs(physics.feet.x - feet.x) <= 1 && abs(physics.feet.y - feet.y) <= 1, "전환 시 발 위치 유지")
            try check(atlas.allSprites.contains { $0.image === dogView.sprite.image }, "새 캐릭터 이미지 표시")
            try check(characterItems[choice]?.state == .on &&
                      characterItems.filter { $0.key != choice }.allSatisfy { $0.value.state == .off }, "메뉴 선택 상태")
            try check(physics.wrapHalfWidth == dogHeight * atlas.windowWidthRatio / 2, "캐릭터 너비에 맞춘 화면 연결")
            physics.advance(by: 1.0 / 120)
            let cursor = CGPoint(x: physics.feet.x + 80, y: physics.feet.y + 200)
            try check(beginCursorPlay(at: cursor, automatic: false), "전환 후 커서 잡기")
            for _ in 0..<100 {
                if heldCursor.hidden { break }
                advanceCursorPlay(by: 1.0 / 30, cursor: cursor, buttons: 0)
            }
            try check(heldCursor.hidden, "커서 잡은 상태 도달")
            let other: PetCharacter = choice == .puppy ? .bonobono : .puppy
            changeCharacter(characterItems[other]!)
            try check(cursorPlay == nil && !heldCursor.hidden && hides == shows && dogView.cursorAttachment == nil,
                      "커서를 잡은 중에도 캐릭터 전환 시 복구")
            try check(hop == nil && pendingHop == nil && !isClimbing, "이전 캐릭터 행동 정리")
        }
        print("PASS: 실제 창의 강아지 ↔ 보노보노 전환·메뉴 체크·발 위치 유지·커서 잡기 중 전환 복구")
    }

    private func verifyCursorWindow() throws {
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw AssetError.invalid("커서 창 검사: \(message)") }
        }
        if panel == nil { makeMenu(); makePanel() }
        if keyboardMode { setKeyboardMode(false) }
        stopActivity()
        cancelHop()
        var hides = 0, shows = 0
        heldCursor = HeldCursor(hide: { hides += 1; return true }, show: { shows += 1 })
        defer { cancelCursorPlay() }
        func start() throws -> CGPoint {
            physics.teleport(to: CGPoint(x: physics.area.midX, y: physics.area.minY))
            physics.updateLedges([])
            physics.advance(by: 1.0 / 120)
            let target = CGPoint(x: physics.feet.x + 100, y: physics.feet.y + 200)
            try check(beginCursorPlay(at: target, automatic: false), "커서 좌표를 목표로 도약 시작")
            return target
        }
        let target = try start()
        var sawHold = false, sawRoll = false, sawFall = false
        for _ in 0..<350 {
            guard cursorPlay != nil else { break }
            advanceCursorPlay(by: 1.0 / 30, cursor: target, buttons: 0)
            if cursorPlay?.phase == .holding {
                sawHold = true
                let offset = atlas.cursorAttachment(rolling: false, frame: 4).offset(in: atlas.cursorJump[4], height: dogHeight, mirrored: false)
                try check(abs(panel.frame.midX + dogView.renderOffset.x + offset.x - target.x) < 0.01 &&
                          abs(panel.frame.minY + dogView.renderOffset.y + 6 + offset.y - target.y) < 0.01,
                          "화면상의 앞발이 커서와 일치: 창=\(panel.frame), 접점=\(offset), 목표=\(target)")
                try check(heldCursor.hidden && dogView.cursorAttachment != nil, "커서 그림을 앞발에 표시")
            }
            sawFall = sawFall || cursorPlay?.phase == .falling
            sawRoll = sawRoll || cursorPlay?.rolling == true
        }
        try check(sawHold && sawFall && sawRoll && cursorPlay == nil && physics.grounded,
                  "잡기 → 중력 하강 → 창/바닥 착지 → 구르기 → 유휴 복귀")
        try check(hides == 1 && shows == 1 && !heldCursor.hidden && dogView.cursorAttachment == nil,
                  "완주 후 커서 표시 복구")
        for interruption in 0..<3 {
            let cursor = try start()
            for _ in 0..<100 {
                if cursorPlay?.hasCursor == true { break }
                advanceCursorPlay(by: 1.0 / 30, cursor: cursor, buttons: 0)
            }
            try check(heldCursor.hidden, "취소 전 커서 잡기")
            if interruption == 0 {
                advanceCursorPlay(by: 1.0 / 30, cursor: CGPoint(x: cursor.x + 2, y: cursor.y), buttons: 0)
            } else if interruption == 1 {
                advanceCursorPlay(by: 1.0 / 30, cursor: cursor, buttons: 1)
            } else { stopActivity() }
            try check(cursorPlay == nil && !heldCursor.hidden && hides == shows, "이동·클릭·일시정지 취소 복구")
        }
        print("PASS: 실제 창의 커서 접점·중력 착지·구르기·입력 취소·숨김/표시 균형 (시스템 커서는 검사 중 변경하지 않음)")
    }

    private func verifyKeyboardWindow() throws {
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw AssetError.invalid("조종 창 검사: \(message)") }
        }
        makeMenu()
        makePanel()
        setKeyboardMode(true)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        try check(panel.isKeyWindow && panel.firstResponder === dogView,
                  "강아지 창 포커스: key=\(panel.isKeyWindow), accepts=\(panel.canBecomeKey), responder=\(String(describing: panel.firstResponder))")
        try check(roamingTimer == nil, "조종 중 자동 행동 타이머 중지")
        physics.teleport(to: CGPoint(x: physics.area.midX, y: physics.area.minY))
        physics.updateLedges([])
        physics.advance(by: 1.0 / 120)
        cancelHop()
        nextSceneRefresh = .infinity

        func send(_ type: NSEvent.EventType, code: UInt16, characters: String,
                  modifiers: NSEvent.ModifierFlags = []) throws {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code) else { throw AssetError.invalid("키 이벤트를 만들 수 없습니다.") }
            panel.sendEvent(event)
        }
        func step() {
            lastPhysicsTime = ProcessInfo.processInfo.systemUptime - 0.1
            physicsTick()
        }
        let start = physics.feet.x
        try send(.keyDown, code: 2, characters: "d")
        step()
        try check(physics.feet.x > start + 8, "D 입력이 창을 실제로 이동시킴")
        try send(.keyUp, code: 2, characters: "d")
        let stopped = physics.feet.x
        step()
        try check(abs(physics.feet.x - stopped) < 0.01, "D 해제 후 즉시 정지")
        try send(.keyDown, code: 2, characters: "D", modifiers: .shift)
        step()
        try check(gait == .running && physics.feet.x > stopped + 17, "Shift+D 실제 달리기")
        try send(.keyUp, code: 2, characters: "D")
        try send(.keyDown, code: 49, characters: " ")
        try check(hop?.phase == .preparing, "스페이스가 준비 스프라이트를 시작함")
        try send(.keyUp, code: 49, characters: " ")
        step()
        step()
        try check(!physics.grounded && physics.feet.y > physics.area.minY + 20, "스페이스 실제 도약")
        try send(.keyDown, code: 53, characters: "\u{1b}")
        try check(!keyboardMode && !panel.keyboardEnabled && roamingTimer != nil, "Esc가 자동 모드로 복귀시킴")
        print("PASS: 조종 창 포커스·네이티브 키 이벤트·실제 이동·달리기·점프·자동 모드 복귀")
    }

    private func renderHopPreview(to url: URL) throws {
        if !atlas.leaping.isEmpty {
            let steps = ["준비", "발구르기", "상승", "정점", "하강", "착지 직전", "착지", "회복"]
            try renderGrid(atlas.leaping.enumerated().map { ($0.element, steps[$0.offset], false) }, to: url)
            return
        }
        let entries = (atlas.jumping + atlas.descending).enumerated().map { index, sprite in
            let step = ["준비", "공중", "착지 직전", "착지"][index % 4]
            return (sprite, "\(index < 4 ? "도약" : "하강") · \(step)", false)
        }
        try renderGrid(entries, to: url)
    }

    private func renderRunningPreview(to url: URL) throws {
        let entries = (atlas.running + atlas.running).enumerated().map { index, sprite in
            (sprite, "\(index < 8 ? "오른쪽" : "왼쪽") 달리기 \(index % 8 + 1)", index >= 8)
        }
        try renderGrid(entries, to: url)
    }

    private func renderGrid(_ entries: [(DogSprite, String, Bool)], to url: URL, cursorPreview: Bool = false) throws {
        let rows = (entries.count + 3) / 4
        let width = 960, height = rows * 220
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw AssetError.invalid("도약 미리보기를 만들 수 없습니다.")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.21, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: width, height: height).fill()
        for (index, entry) in entries.enumerated() {
            let (sprite, label, mirrored) = entry
            let canvas = CGRect(x: (index % 4) * 240, y: (rows - 1 - index / 4) * 220 + 30,
                                width: 240, height: 172)
            sprite.draw(in: canvas, height: 160, mirrored: mirrored)
            if cursorPreview && index >= 4 {
                let attachment = atlas.cursorAttachment(rolling: index >= 8, frame: index % 8)
                attachment.draw(in: canvas, sprite: sprite, height: 160, mirrored: mirrored)
            }
            (label as NSString).draw(at: CGPoint(x: canvas.minX + 65, y: canvas.minY - 18),
                withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white])
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw AssetError.invalid("도약 미리보기를 저장할 수 없습니다.")
        }
        try png.write(to: url)
    }

    private func renderPreview(to url: URL) throws {
        let width = 720, height = 1980
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw AssetError.invalid("미리보기를 만들 수 없습니다.")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.21, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: width, height: height).fill()
        context.imageInterpolation = .none
        let sprites = [atlas.resting] + atlas.idle + atlas.walking + (atlas.walkingLeft ?? atlas.walking)
        for (index, sprite) in sprites.enumerated() {
            let canvas = CGRect(x: (index % 3) * 240, y: (8 - index / 3) * 220 + 30,
                                width: 240, height: 172)
            sprite.draw(in: canvas, height: 160, mirrored: index >= 17 && atlas.walkingLeft == nil)
            let label: String
            if index == 0 { label = "기본 정지 포즈" }
            else if index < 9 { label = "대기 프레임 \(index)" }
            else if index < 17 { label = "오른쪽 걷기 \(index - 8)" }
            else { label = "왼쪽 걷기 \(index - 16)" }
            (label as NSString).draw(at: CGPoint(x: canvas.minX + 65, y: canvas.minY - 18),
                withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white])
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw AssetError.invalid("미리보기를 저장할 수 없습니다.")
        }
        try png.write(to: url)
    }
}
