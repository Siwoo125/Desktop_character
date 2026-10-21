import AppKit
import UniformTypeIdentifiers

private final class CreatorDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class CharacterCreator: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    let store: CustomCharacterStore
    let imagesRoot: URL
    var files: [CharacterSlot: URL] = [:]
    var grips: [String: [CharacterGrip]]
    var onCreated: ((CustomCharacter, SpriteAtlas) -> Void)?
    var onClosed: (() -> Void)?
    let nameField = NSTextField()
    let templatePicker = NSPopUpButton()
    let layoutPicker = NSPopUpButton()
    let saveButton = NSButton(title: "저장하고 사용", target: nil, action: nil)
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    let aiStore: AIConnectionStore
    let aiPicker = NSPopUpButton(), directorPicker = NSPopUpButton()
    let generateAllButton = NSButton(title: "전체 모션 만들기", target: nil, action: nil)
    let cancelAIButton = NSButton(title: "생성 중단", target: nil, action: nil)
    let overwriteAI = NSButton(checkboxWithTitle: "기존 모션도 다시 만들기", target: nil, action: nil)
    let aiStatus = NSTextField(wrappingLabelWithString: "정지 PNG만 선택한 뒤 API를 추가·검증하세요. 생성 시 정지 이미지와 선택한 동작 예시를 해당 서비스에 전송하며 API 요금이 발생할 수 있습니다.")
    var aiService = AIMotionService()
    private var aiWindow: AIConnectionsWindow?
    private var aiTask: Task<Void, Never>?
    private var aiBusy = false
    private var aiClosed = false
    private let aiFolder = FileManager.default.temporaryDirectory.appendingPathComponent("DesktopCharacter-AI-" + UUID().uuidString)
    private var aiButtons: [CharacterSlot: NSButton] = [:]
    private var chooseButtons: [NSButton] = []
    private var aiManageButton: NSButton!
    private var template: PetCharacter
    private var sampleViews: [CharacterSlot: NSImageView] = [:]
    private var uploadViews: [CharacterSlot: NSImageView] = [:]
    private var fileLabels: [CharacterSlot: NSTextField] = [:]
    private var previewButtons: [CharacterSlot: NSButton] = [:]
    private var preview: CharacterAnimationPreview?
    private var extraReferences: [NSImageView] = []

    init(store: CustomCharacterStore, imagesRoot: URL, template: PetCharacter, aiConnections: AIConnectionStore? = nil) {
        self.store = store
        self.imagesRoot = imagesRoot
        self.template = template
        aiStore = aiConnections ?? AIConnectionStore(url: store.root.deletingLastPathComponent().appendingPathComponent("ai-connections.json"))
        grips = CustomCharacter.defaultGrips(template)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 840),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "캐릭터 생성"
        window.minSize = NSSize(width: 940, height: 700)
        window.isReleasedWhenClosed = false
        window.delegate = self
        build()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func label(_ text: String, bold: Bool = false) -> NSTextField {
        let result = NSTextField(wrappingLabelWithString: text)
        result.font = bold ? .boldSystemFont(ofSize: 14) : .systemFont(ofSize: 12)
        result.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return result
    }

    private func imageView() -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1).cgColor
        view.layer?.cornerRadius = 8
        view.widthAnchor.constraint(equalToConstant: 192).isActive = true
        view.heightAnchor.constraint(equalToConstant: 100).isActive = true
        return view
    }

    private func build() {
        guard let content = window?.contentView else { return }
        let outer = NSStackView()
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 12
        outer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(outer)
        NSLayoutConstraint.activate([outer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            outer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            outer.topAnchor.constraint(equalTo: content.topAnchor, constant: 18), outer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)])
        let heading = label("내 이미지로 만드는 바탕화면 친구", bold: true)
        heading.font = .boldSystemFont(ofSize: 22)
        outer.addArrangedSubview(heading)
        outer.addArrangedSubview(label("① 예시처럼 동작별 PNG 준비 → ② 이미지 선택 · 미리보기 → ③ 이름을 정하고 저장\n투명 배경으로 몸 전체를 각 칸 안에 그려 주세요. 8프레임은 4칸 × 2줄, 윗줄 왼쪽부터 재생합니다. 예: 2048 × 1024 시트. 필수 8종이며 왼쪽 걷기는 선택입니다."))
        nameField.stringValue = store.suggestedName()
        nameField.placeholderString = "캐릭터 이름 (1~40자)"
        nameField.delegate = self
        nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 210).isActive = true
        let suggest = NSButton(title: "이름 추천", target: self, action: #selector(suggestName))
        templatePicker.addItems(withTitles: ["강아지 예시", "보노보노 예시"])
        templatePicker.selectItem(at: template == .puppy ? 0 : 1)
        templatePicker.target = self
        templatePicker.action = #selector(changeTemplate)
        let export = NSButton(title: "예시 세트 저장…", target: self, action: #selector(exportExamples))
        let naming = NSStackView(views: [label("이름", bold: true), nameField, suggest, templatePicker, export])
        naming.spacing = 10
        outer.addArrangedSubview(naming)
        layoutPicker.addItems(withTitles: ["두 동작: 윗줄 위로 점프 4장 / 아랫줄 하강 4장", "한 동작: 준비 → 발구르기 → 상승 → 정점 → 하강 → 착지 직전 → 착지 → 회복"])
        layoutPicker.selectItem(at: template == .puppy ? 0 : 1)
        let layout = NSStackView(views: [label("점프 시트 순서", bold: true), layoutPicker])
        layout.spacing = 10
        outer.addArrangedSubview(layout)
        aiManageButton = NSButton(title: "API 추가 · 검증…", target: self, action: #selector(openAISettings))
        aiPicker.target = self; aiPicker.action = #selector(selectAI)
        directorPicker.target = self; directorPicker.action = #selector(selectAI)
        directorPicker.widthAnchor.constraint(lessThanOrEqualToConstant: 250).isActive = true
        directorPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        aiPicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        let apiRow = NSStackView(views: [label("이미지 API", bold: true), aiPicker, aiManageButton])
        apiRow.spacing = 10; outer.addArrangedSubview(apiRow)
        generateAllButton.target = self; generateAllButton.action = #selector(generateAll)
        cancelAIButton.target = self; cancelAIButton.action = #selector(cancelAI); cancelAIButton.isEnabled = false
        let aiActions = NSStackView(views: [generateAllButton, overwriteAI, cancelAIButton, label("Claude 보조 (선택)"), directorPicker])
        aiActions.spacing = 10; outer.addArrangedSubview(aiActions)
        aiStatus.textColor = .secondaryLabelColor
        outer.addArrangedSubview(aiStatus)
        aiStatus.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
        reloadAI()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        outer.addArrangedSubview(scroll)
        let document = CreatorDocument()
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 14
        rows.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        scroll.documentView = document
        NSLayoutConstraint.activate([scroll.widthAnchor.constraint(equalTo: outer.widthAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 2),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16),
            rows.topAnchor.constraint(equalTo: document.topAnchor, constant: 6), rows.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -12)])
        for (index, slot) in CharacterSlot.allCases.enumerated() {
            let sample = imageView(), uploaded = imageView()
            sampleViews[slot] = sample
            uploadViews[slot] = uploaded
            let left = NSStackView(views: [label("예시 · \(slot.title)", bold: true), sample])
            left.orientation = .vertical; left.alignment = .leading; left.spacing = 6
            let filename = label(slot.required ? "아직 선택하지 않았습니다 · 필수" : "없으면 자동 좌우 반전")
            filename.widthAnchor.constraint(equalToConstant: 192).isActive = true
            fileLabels[slot] = filename
            let middle = NSStackView(views: [filename, uploaded])
            middle.orientation = .vertical; middle.alignment = .leading; middle.spacing = 6
            let choose = NSButton(title: "이미지 선택…", target: self, action: #selector(chooseImage(_:)))
            choose.tag = index
            chooseButtons.append(choose)
            let play = NSButton(title: "미리보기 · 재생", target: self, action: #selector(previewImage(_:)))
            play.tag = index; play.isEnabled = false
            previewButtons[slot] = play
            let original = NSButton(title: "예시 크게 보기", target: self, action: #selector(showExample(_:)))
            original.tag = index
            let buttons = NSStackView(views: [label(slot.guide), choose, play, original])
            let generate = NSButton(title: slot == .standing ? "이 정지 자세로 전체 만들기" : "이 모션만 다시 만들기", target: self, action: #selector(generateOne(_:)))
            generate.tag = index; aiButtons[slot] = generate
            buttons.addArrangedSubview(generate)
            buttons.orientation = .vertical; buttons.alignment = .leading; buttons.spacing = 6
            let row = NSStackView(views: [left, middle, buttons])
            row.spacing = 18
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            let separator = NSBox(); separator.boxType = .separator
            rows.addArrangedSubview(separator)
            separator.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        rows.addArrangedSubview(label("커서가 그려진 원본도 참고하세요 (참고용 2장)\n커서는 앱이 직접 표시합니다. 실제 등록에는 위의 ‘커서 없는’ 점프·구르기 이미지를 사용하세요.", bold: true))
        let extra = NSStackView()
        extra.spacing = 12
        for filename in ["08-cursor-jump.png", "10-cursor-roll.png"] {
            let view = imageView()
            view.image = NSImage(contentsOf: imagesRoot.appendingPathComponent("bonobono-sprites/" + filename))
            extraReferences.append(view)
            let box = NSStackView(views: [label(filename), view])
            box.orientation = .vertical; box.alignment = .leading; box.spacing = 4
            extra.addArrangedSubview(box)
        }
        rows.addArrangedSubview(extra)
        statusLabel.textColor = .secondaryLabelColor
        outer.addArrangedSubview(statusLabel)
        saveButton.target = self; saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        let cancel = NSButton(title: "취소", target: self, action: #selector(cancelCreation))
        let footer = NSStackView(views: [cancel, saveButton]); footer.spacing = 12
        outer.addArrangedSubview(footer)
        updateExamples()
        updateStatus()
    }

    private func updateExamples() {
        for slot in CharacterSlot.allCases { sampleViews[slot]?.image = NSImage(contentsOf: slot.example(template, in: imagesRoot)) }
    }
    func updateStatus() {
        let count = CharacterSlot.allCases.filter { $0.required && files[$0] != nil }.count
        let validName = !nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && nameField.stringValue.count <= 40
        statusLabel.stringValue = "필수 이미지 \(count)/8 · 저장하면 이미지를 앱 보관함에 복사하고 새 캐릭터 한 마리를 추가합니다. 원본 파일은 수정하지 않습니다."
        statusLabel.textColor = .secondaryLabelColor
        saveButton.isEnabled = count == 8 && validName && !aiBusy
    }
    func controlTextDidChange(_ obj: Notification) { updateStatus() }
    @objc private func suggestName() { nameField.stringValue = store.suggestedName(); updateStatus() }
    @objc private func exportExamples() {
        let picker = NSOpenPanel()
        picker.canChooseFiles = false; picker.canChooseDirectories = true; picker.canCreateDirectories = true
        picker.message = "선택한 위치에 예시 PNG와 만드는 방법을 새 폴더로 저장합니다."
        guard picker.runModal() == .OK, let parent = picker.url else { return }
        do { NSWorkspace.shared.open(try CustomCharacterStore.exportExamples(template: template, imagesRoot: imagesRoot, parent: parent)) }
        catch { showError(error) }
    }
    @objc private func changeTemplate() {
        template = templatePicker.indexOfSelectedItem == 0 ? .puppy : .bonobono
        grips = CustomCharacter.defaultGrips(template)
        layoutPicker.selectItem(at: template == .puppy ? 0 : 1)
        preview?.close()
        updateExamples()
    }
    @objc private func chooseImage(_ sender: NSButton) {
        let slot = CharacterSlot.allCases[sender.tag]
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.png]
        picker.allowsMultipleSelection = false
        picker.message = "\(slot.title) · \(slot.guide)"
        guard picker.runModal() == .OK, let url = picker.url else { return }
        do { try assign(url, to: slot) } catch { showError(error) }
    }
    func assign(_ url: URL, to slot: CharacterSlot) throws {
        try CustomCharacterStore.validatePNG(url, slot: slot)
        files[slot] = url
        uploadViews[slot]?.image = NSImage(contentsOf: url)
        fileLabels[slot]?.stringValue = url.lastPathComponent
        previewButtons[slot]?.isEnabled = true
        updateStatus()
    }
    @objc private func previewImage(_ sender: NSButton) {
        let slot = CharacterSlot.allCases[sender.tag]
        guard let url = files[slot] else { return }
        do {
            preview?.close()
            let frames = try SpriteAtlas.customFrames(url, slot: slot)
            let key = slot == .cursorJump ? "jump" : slot == .cursorRoll ? "roll" : nil
            let viewer = CharacterAnimationPreview(title: slot.title, frames: frames, grips: key.flatMap { grips[$0] })
            viewer.onGrip = { [weak self] index, point in
                guard let self, let key else { return }
                self.grips[key]?[index] = point
            }
            preview = viewer
            viewer.showWindow(nil)
            viewer.window?.makeKeyAndOrderFront(nil)
        } catch { showError(error) }
    }
    @objc private func showExample(_ sender: NSButton) {
        let slot = CharacterSlot.allCases[sender.tag]
        guard let image = NSImage(contentsOf: slot.example(template, in: imagesRoot)) else { return }
        preview?.close()
        let frame = DogSprite(image: image, headCenterX: image.size.width / 2, pixelSize: image.size)
        preview = CharacterAnimationPreview(title: "예시 · \(slot.title)", frames: [frame], grips: nil)
        preview?.showWindow(nil)
        preview?.window?.makeKeyAndOrderFront(nil)
    }
    @objc func save() {
        do {
            let (profile, atlas) = try store.create(name: nameField.stringValue, template: template,
                leapLayout: layoutPicker.indexOfSelectedItem == 0 ? "split" : "continuous", files: files, grips: grips)
            onCreated?(profile, atlas)
            close()
        } catch { showError(error) }
    }
    private func showError(_ error: Error) { statusLabel.stringValue = error.localizedDescription; statusLabel.textColor = .systemRed }
    @objc private func cancelCreation() { close() }
    func windowWillClose(_ notification: Notification) {
        aiClosed = true; aiTask?.cancel(); aiWindow?.close(); aiWindow = nil
        try? FileManager.default.removeItem(at: aiFolder)
        preview?.close(); preview = nil; onClosed?()
    }

    private var renderers: [AIConnection] { aiStore.state.connections.filter(\.imageCapable) }
    var isGenerating: Bool { aiBusy }
    private var directors: [AIConnection] { aiStore.state.connections.filter { $0.provider == "anthropic" } }
    func reloadAI() {
        aiPicker.removeAllItems(); aiPicker.addItem(withTitle: "이미지 생성 API 선택")
        aiPicker.addItems(withTitles: renderers.map { ($0.verified_at == nil ? "미검증 · " : "✓ ") + $0.name })
        directorPicker.removeAllItems(); directorPicker.addItem(withTitle: "사용 안 함")
        directorPicker.addItems(withTitles: directors.map { ($0.verified_at == nil ? "미검증 · " : "✓ ") + $0.name })
        if let index = renderers.firstIndex(where: { $0.id == aiStore.state.renderer_id }) { aiPicker.selectItem(at: index+1) }
        else if !renderers.isEmpty { aiPicker.selectItem(at: 1) }
        if let index = directors.firstIndex(where: { $0.id == aiStore.state.director_id }) { directorPicker.selectItem(at: index+1) }
    }
    @objc private func selectAI() {
        let r = aiPicker.indexOfSelectedItem-1, d = directorPicker.indexOfSelectedItem-1
        aiStore.state.renderer_id = renderers.indices.contains(r) ? renderers[r].id : nil
        aiStore.state.director_id = directors.indices.contains(d) ? directors[d].id : nil
        do { try aiStore.persist() } catch { showError(error) }
    }
    @objc private func openAISettings() {
        if let aiWindow { aiWindow.showWindow(nil); aiWindow.window?.makeKeyAndOrderFront(nil); return }
        let settings = AIConnectionsWindow(store: aiStore)
        settings.onChange = { [weak self] in self?.reloadAI() }
        settings.onClosed = { [weak self] in self?.aiWindow = nil }
        aiWindow = settings; settings.showWindow(nil); settings.window?.makeKeyAndOrderFront(nil)
    }
    @objc private func generateAll() {
        makeMotions(CharacterSlot.allCases.filter { $0 != .standing && (overwriteAI.state == .on || files[$0] == nil) })
    }
    @objc private func generateOne(_ sender: NSButton) {
        let slot = CharacterSlot.allCases[sender.tag]
        if slot == .standing { generateAll() } else { makeMotions([slot]) }
    }
    @objc private func cancelAI() {
        aiTask?.cancel(); cancelAIButton.isEnabled = false
        aiStatus.stringValue = "취소 요청 중… 진행 중이던 요청은 과금될 수 있습니다. 완료한 모션은 유지합니다."
    }
    private func setAIBusy(_ busy: Bool) {
        aiBusy = busy; generateAllButton.isEnabled = !busy; cancelAIButton.isEnabled = busy
        for button in aiButtons.values { button.isEnabled = !busy }
        for button in chooseButtons { button.isEnabled = !busy }
        templatePicker.isEnabled = !busy; layoutPicker.isEnabled = !busy; aiPicker.isEnabled = !busy
        directorPicker.isEnabled = !busy; aiManageButton.isEnabled = !busy; overwriteAI.isEnabled = !busy
        updateStatus()
    }
    func makeMotions(_ slots: [CharacterSlot]) {
        guard !aiBusy else { return }
        do {
            guard !slots.isEmpty else { throw AIError.message("모든 모션이 있습니다. 개별 재생성 또는 ‘기존 모션도 다시 만들기’를 선택하세요.") }
            guard let originalStanding = files[.standing] else { throw AIError.message("기본 정지 자세 PNG를 먼저 선택하세요.") }
            let index = aiPicker.indexOfSelectedItem-1
            guard renderers.indices.contains(index), renderers[index].verified_at != nil else { throw AIError.message("이미지 API를 추가·검증하고 선택하세요.") }
            let renderer = renderers[index], key = try aiStore.secrets.get(renderer.id)
            let d = directorPicker.indexOfSelectedItem-1
            let director = directors.indices.contains(d) ? directors[d] : nil
            if let director, director.verified_at == nil { throw AIError.message("Claude 보조 API도 먼저 검증하세요.") }
            let directorKey = try director.map { try aiStore.secrets.get($0.id) }
            let layout = layoutPicker.indexOfSelectedItem == 0 ? "split" : "continuous", base = template
            try FileManager.default.createDirectory(at: aiFolder, withIntermediateDirectories: true)
            let standing = aiFolder.appendingPathComponent(UUID().uuidString + "-standing.png")
            try FileManager.default.copyItem(at: originalStanding, to: standing)
            let service = aiService
            setAIBusy(true); aiStatus.textColor = .secondaryLabelColor
            aiTask = Task { [weak self] in
                guard let self else { return }
                var completed = 0
                defer { if !self.aiClosed { self.setAIBusy(false); self.aiTask = nil } }
                do {
                    for slot in slots {
                        try Task.checkCancellation()
                        self.aiStatus.stringValue = "\(completed)/\(slots.count) · \(slot.title) 생성 중… 정지 이미지 + 모션 예시 전송"
                        let output = self.aiFolder.appendingPathComponent(UUID().uuidString + "-" + slot.filename)
                        let url = try await service.generate(profile: renderer, key: key, slot: slot, layout: layout,
                            standing: standing, example: slot.example(base, in: self.imagesRoot), destination: output,
                            mirror: base == .puppy && slot == .walkLeft, director: director, directorKey: directorKey)
                        try Task.checkCancellation()
                        guard !self.aiClosed else { return }
                        try self.assign(url, to: slot)
                        if slot == .cursorJump { self.grips["jump"] = CustomCharacter.defaultGrips(base)["jump"] }
                        if slot == .cursorRoll { self.grips["roll"] = CustomCharacter.defaultGrips(base)["roll"] }
                        completed += 1
                    }
                    self.aiStatus.stringValue = "\(completed)개 모션 생성 완료. 미리보기로 자세와 커서 손 위치를 확인한 뒤 저장하세요."
                } catch {
                    guard !self.aiClosed else { return }
                    self.aiStatus.textColor = .systemRed
                    self.aiStatus.stringValue = "\(completed)/\(slots.count) 완료 · " + (Task.isCancelled ? "생성을 취소했습니다. 진행 중 요청은 과금될 수 있습니다." : error.localizedDescription) + " 완료한 모션과 기존 이미지는 유지합니다."
                }
            }
        } catch { aiStatus.textColor = .systemRed; aiStatus.stringValue = error.localizedDescription }
    }
}

@MainActor
private final class FrameCanvas: NSView {
    var sprite: DogSprite?
    var grip: CharacterGrip?
    var onPick: ((CharacterGrip) -> Void)?
    private var imageRect = CGRect.zero
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill(); bounds.fill()
        guard let sprite else { return }
        let scale = min((bounds.width - 40) / sprite.pixelSize.width, (bounds.height - 40) / sprite.pixelSize.height)
        imageRect = CGRect(x: bounds.midX - sprite.pixelSize.width * scale / 2, y: bounds.midY - sprite.pixelSize.height * scale / 2,
                           width: sprite.pixelSize.width * scale, height: sprite.pixelSize.height * scale)
        NSGraphicsContext.current?.imageInterpolation = .none
        sprite.image.draw(in: imageRect)
        if let grip {
            let point = CGPoint(x: imageRect.minX + grip.x * imageRect.width, y: imageRect.minY + grip.y * imageRect.height)
            NSColor.systemTeal.setFill()
            NSBezierPath(ovalIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)).fill()
            NSCursor.arrow.image.draw(in: CGRect(x: point.x - 8, y: point.y, width: 22, height: 26))
        }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard onPick != nil, imageRect.contains(point) else { return }
        let grip = CharacterGrip(x: (point.x - imageRect.minX) / imageRect.width, y: (point.y - imageRect.minY) / imageRect.height)
        self.grip = grip; needsDisplay = true; onPick?(grip)
    }
}

@MainActor
final class CharacterAnimationPreview: NSWindowController, NSWindowDelegate {
    var onGrip: ((Int, CharacterGrip) -> Void)?
    private let frames: [DogSprite]
    private var points: [CharacterGrip]?
    private let canvas = FrameCanvas()
    private let picker = NSPopUpButton()
    private let playButton = NSButton(title: "재생", target: nil, action: nil)
    private var timer: Timer?
    init(title: String, frames: [DogSprite], grips: [CharacterGrip]?) {
        self.frames = frames; points = grips
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 660, height: 500), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = title; window.isReleasedWhenClosed = false; window.delegate = self
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -16), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -16)])
        canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        stack.addArrangedSubview(canvas)
        canvas.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        picker.addItems(withTitles: frames.indices.map { "프레임 \($0 + 1)" })
        picker.target = self; picker.action = #selector(selectFrame)
        playButton.target = self; playButton.action = #selector(togglePlay)
        playButton.isEnabled = frames.count > 1
        stack.addArrangedSubview(NSStackView(views: [picker, playButton]))
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString: grips == nil ? "재생으로 프레임 순서를 확인하세요." : "프레임을 고른 뒤 잡는 손 부분을 클릭하세요. 청록색 점이 커서 접점입니다. 점프는 5~8번, 구르기는 모든 프레임에 적용됩니다."))
        canvas.onPick = grips == nil ? nil : { [weak self] point in
            self?.placeGrip(point)
        }
        selectFrame()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func chooseFrame(_ index: Int) {
        guard frames.indices.contains(index) else { return }
        picker.selectItem(at: index); selectFrame()
    }
    func placeGrip(_ point: CharacterGrip) {
        guard points != nil else { return }
        stop()
        let index = picker.indexOfSelectedItem
        points?[index] = point
        selectFrame()
        onGrip?(index, point)
    }
    @objc private func selectFrame() {
        let index = picker.indexOfSelectedItem
        canvas.sprite = frames[index]; canvas.grip = points?[index]; canvas.needsDisplay = true
    }
    private func stop() { timer?.invalidate(); timer = nil; playButton.title = "재생" }
    @objc private func togglePlay() {
        if timer != nil { stop(); return }
        playButton.title = "정지"
        let timer = Timer(timeInterval: 0.14, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.picker.selectItem(at: (self.picker.indexOfSelectedItem + 1) % self.frames.count)
                self.selectFrame()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func windowWillClose(_ notification: Notification) { stop() }
}
