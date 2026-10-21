import AppKit

@MainActor
final class AIConnectionsWindow: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    let store: AIConnectionStore
    var onChange: (() -> Void)?
    var onClosed: (() -> Void)?
    var service = AIMotionService()
    let accountPicker = NSPopUpButton(), providerPicker = NSPopUpButton()
    let nameField = NSTextField(), modelField = NSTextField(), keyField = NSSecureTextField()
    let status = NSTextField(wrappingLabelWithString: "")
    let addButton = NSButton(title: "추가", target: nil, action: nil)
    let updateButton = NSButton(title: "변경 저장", target: nil, action: nil)
    let verifyButton = NSButton(title: "검증", target: nil, action: nil)
    let deleteButton = NSButton(title: "삭제", target: nil, action: nil)
    private var verifiedAt: Double?
    private var task: Task<Void, Never>?
    private let providers = ["openai", "gemini", "anthropic"]
    private var selected: AIConnection? {
        let index = accountPicker.indexOfSelectedItem - 1
        return store.state.connections.indices.contains(index) ? store.state.connections[index] : nil
    }
    init(store: AIConnectionStore) {
        self.store = store
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 680, height: 450), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "개인 API 추가 · 검증"; window.isReleasedWhenClosed = false; window.delegate = self
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20)])
        func row(_ title: String, _ control: NSView) {
            let label = NSTextField(labelWithString: title); label.widthAnchor.constraint(equalToConstant: 95).isActive = true
            let line = NSStackView(views: [label, control]); line.spacing = 10
            stack.addArrangedSubview(line); line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        accountPicker.target = self; accountPicker.action = #selector(selectAccount)
        row("저장한 API", accountPicker)
        providerPicker.addItems(withTitles: providers.map { AIProvider.names[$0]! })
        providerPicker.target = self; providerPicker.action = #selector(changeProvider)
        row("서비스", providerPicker)
        nameField.placeholderString = "예: 내 이미지 생성 API"; modelField.placeholderString = "모델 ID (수정 가능)"
        keyField.placeholderString = "개인 API 키 · 화면에 표시하지 않음"
        for field in [nameField, modelField, keyField] { field.delegate = self }
        row("이름", nameField); row("모델 ID", modelField); row("API 키", keyField)
        let help = NSTextField(wrappingLabelWithString: "API 키는 macOS 키체인에 저장합니다. ChatGPT·Claude·Gemini 웹 구독과 API 요금은 별도일 수 있습니다. 검증은 모델 조회만 하며 이미지 생성 요청은 보내지 않습니다.\nClaude는 설명 보조용입니다. 실제 시트에는 OpenAI 또는 Gemini 이미지 API가 필요합니다.")
        stack.addArrangedSubview(help); help.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        for (button, selector) in [(addButton, #selector(add)), (updateButton, #selector(update)), (verifyButton, #selector(verify)), (deleteButton, #selector(remove))] { button.target = self; button.action = selector }
        let keyPage = NSButton(title: "API 키 발급 페이지", target: self, action: #selector(openKeyPage))
        let buttons = NSStackView(views: [addButton, updateButton, verifyButton, deleteButton, keyPage]); buttons.spacing = 10
        stack.addArrangedSubview(buttons)
        status.textColor = .secondaryLabelColor
        stack.addArrangedSubview(status); status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        reload(); selectAccount(); window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func reload(id: String? = nil) {
        accountPicker.removeAllItems(); accountPicker.addItem(withTitle: "새 API 추가")
        accountPicker.addItems(withTitles: store.state.connections.map { ($0.verified_at == nil ? "미검증 · " : "✓ ") + $0.name })
        if let id, let index = store.state.connections.firstIndex(where: { $0.id == id }) { accountPicker.selectItem(at: index + 1) }
    }
    @objc private func selectAccount() {
        task?.cancel(); task = nil; setBusy(false)
        verifiedAt = selected?.verified_at
        if let selected {
            providerPicker.selectItem(at: providers.firstIndex(of: selected.provider)!)
            nameField.stringValue = selected.name; modelField.stringValue = selected.model
            keyField.stringValue = ""; keyField.placeholderString = "키 유지 · 변경할 때만 새 키 입력"
        } else {
            providerPicker.selectItem(at: 0); changeProvider()
            keyField.stringValue = ""; keyField.placeholderString = "개인 API 키"
        }
        status.stringValue = selected?.verified_at == nil ? "검증 후 추가 또는 변경 저장을 누르세요." : "모델 조회 확인됨 · 실제 생성 권한·잔액은 생성 시 확인합니다."
        updateButton.isEnabled = selected != nil; deleteButton.isEnabled = selected != nil
    }
    @objc private func changeProvider() {
        let provider = providers[providerPicker.indexOfSelectedItem]
        modelField.stringValue = (try? AIMotionCatalog.load().defaults[provider]) ?? ""
        nameField.stringValue = AIProvider.names[provider]!
        verifiedAt = nil
        status.stringValue = "설정이 바뀌었습니다. 다시 검증하세요."
    }
    func controlTextDidChange(_ obj: Notification) { verifiedAt = nil; status.stringValue = "설정이 바뀌었습니다. 다시 검증하세요." }
    private func values(fresh: Bool = false) throws -> (AIConnection, String) {
        var profile = AIConnection(provider: providers[providerPicker.indexOfSelectedItem], name: nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), model: modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), verified_at: verifiedAt)
        if !fresh, let selected { profile.id = selected.id }
        try profile.validate()
        let key = keyField.stringValue.isEmpty ? try store.secrets.get(selected?.id ?? "") : try AIError.key(keyField.stringValue)
        return (profile, key)
    }
    private func setBusy(_ busy: Bool) {
        for control in [accountPicker, providerPicker, nameField, modelField, keyField] { control.isEnabled = !busy }
        addButton.isEnabled = !busy; verifyButton.isEnabled = !busy
        updateButton.isEnabled = !busy && selected != nil; deleteButton.isEnabled = !busy && selected != nil
    }
    @objc private func verify() {
        do {
            let (profile, key) = try values()
            setBusy(true); status.stringValue = "모델 조회로 API 연결을 확인하는 중…"
            task = Task { [weak self] in
                do {
                    try await self?.service.verify(profile, key: key)
                    try Task.checkCancellation()
                    guard let self else { return }
                    self.verifiedAt = Date().timeIntervalSince1970
                    self.status.textColor = .secondaryLabelColor
                    self.status.stringValue = "연결·모델 조회 성공. 추가 또는 변경 저장을 누르세요. 생성 권한·잔액·품질은 생성 시 확인합니다."
                    self.setBusy(false); self.task = nil
                } catch {
                    guard !Task.isCancelled, let self else { return }
                    self.verifiedAt = nil; self.fail(error); self.setBusy(false); self.task = nil
                }
            }
        } catch { fail(error) }
    }
    private func save(fresh: Bool) {
        do {
            let (profile, key) = try values(fresh: fresh)
            try store.save(profile, key: key)
            onChange?(); reload(id: profile.id); selectAccount()
            status.stringValue = profile.verified_at == nil ? "저장했습니다. 사용 전에 검증하고 변경 저장을 누르세요." : "검증한 API를 저장했습니다."
        } catch { fail(error) }
    }
    @objc private func add() { save(fresh: true) }
    @objc private func openKeyPage() {
        if let url = URL(string: AIProvider.keyPages[providers[providerPicker.indexOfSelectedItem]]!) { NSWorkspace.shared.open(url) }
    }
    @objc private func update() { save(fresh: false) }
    @objc private func remove() {
        guard let selected else { return }
        do { try store.delete(selected); onChange?(); reload(); selectAccount(); status.stringValue = "API 설정과 키를 삭제했습니다." }
        catch { fail(error) }
    }
    private func fail(_ error: Error) { status.textColor = .systemRed; status.stringValue = error.localizedDescription }
    func windowWillClose(_ notification: Notification) { task?.cancel(); task = nil; keyField.stringValue = ""; onClosed?() }
}
