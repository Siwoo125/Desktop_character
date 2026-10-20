import AppKit

struct CharacterLibraryRow {
    let id: String
    let name: String
    let image: NSImage?
    let count: Int
    let builtin: Bool
}

@MainActor final class CharacterLibraryWindow: NSWindowController, NSWindowDelegate {
    var onAdd: ((String) -> Void)?
    var onRemove: ((String) -> Void)?
    var onDelete: ((String) -> Void)?
    var onCreate: (() -> Void)?
    var onClosed: (() -> Void)?
    private let scroll = NSScrollView()
    private let summary = NSTextField(labelWithString: "")
    private var rows: [CharacterLibraryRow] = []
    private(set) var addButtons: [String: NSButton] = [:]
    private(set) var removeButtons: [String: NSButton] = [:]
    private(set) var deleteButtons: [String: NSButton] = [:]
    init() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 520), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "캐릭터 관리 (+ / −)"; window.minSize = NSSize(width: 640, height: 360)
        window.isReleasedWhenClosed = false; window.delegate = self
        let outer = NSStackView(); outer.orientation = .vertical; outer.alignment = .leading; outer.spacing = 14
        outer.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!; content.addSubview(outer)
        NSLayoutConstraint.activate([outer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), outer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), outer.topAnchor.constraint(equalTo: content.topAnchor, constant: 20), outer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)])
        let heading = NSTextField(labelWithString: "바탕화면에 친구 더하기"); heading.font = .boldSystemFont(ofSize: 23); outer.addArrangedSubview(heading)
        outer.addArrangedSubview(NSTextField(wrappingLabelWithString: "+ 는 한 마리 추가, − 는 한 마리 내리기입니다. 같은 캐릭터도 여러 마리 띄울 수 있어요.\n삭제는 직접 만든 캐릭터를 보관함에서 지웁니다. 강아지·보노보노는 삭제할 수 없습니다."))
        outer.addArrangedSubview(summary)
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        outer.addArrangedSubview(scroll); scroll.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
        let create = NSButton(title: "캐릭터 생성…", target: self, action: #selector(createCharacter))
        let done = NSButton(title: "닫기", target: self, action: #selector(done)); done.keyEquivalent = "\r"
        let footer = NSStackView(views: [create, done]); footer.spacing = 12; outer.addArrangedSubview(footer)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func refresh(rows: [CharacterLibraryRow]) {
        let previousScroll = scroll.contentView.bounds.origin
        self.rows = rows; addButtons.removeAll(); removeButtons.removeAll(); deleteButtons.removeAll()
        summary.stringValue = "화면에 총 \(rows.reduce(0) { $0 + $1.count })마리 · 모두 내려도 메뉴에서 다시 추가할 수 있어요."
        let document = FlippedLibraryView(), stack = NSStackView()
        document.translatesAutoresizingMaskIntoConstraints = false; stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        document.addSubview(stack); scroll.documentView = document
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), stack.leadingAnchor.constraint(equalTo: document.leadingAnchor), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16), stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 6), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -6)])
        for (index, row) in rows.enumerated() {
            let image = NSImageView(); image.image = row.image; image.imageScaling = .scaleProportionallyUpOrDown
            image.widthAnchor.constraint(equalToConstant: 56).isActive = true; image.heightAnchor.constraint(equalToConstant: 64).isActive = true
            let name = NSTextField(wrappingLabelWithString: row.name); name.font = .boldSystemFont(ofSize: 15)
            let kind = NSTextField(labelWithString: row.builtin ? "기본 캐릭터 · 삭제 불가" : "내 캐릭터"); kind.textColor = .secondaryLabelColor
            let labels = NSStackView(views: [name, kind]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 4
            labels.widthAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
            let count = NSTextField(labelWithString: "\(row.count)마리"); count.widthAnchor.constraint(equalToConstant: 54).isActive = true
            let plus = NSButton(title: "+", target: self, action: #selector(add(_:))); plus.tag = index; plus.toolTip = "\(row.name) 한 마리 추가"
            let minus = NSButton(title: "−", target: self, action: #selector(remove(_:))); minus.tag = index; minus.isEnabled = row.count > 0; minus.toolTip = "\(row.name) 한 마리 내리기"
            for button in [plus, minus] { button.widthAnchor.constraint(equalToConstant: 42).isActive = true; button.font = .boldSystemFont(ofSize: 20) }
            let delete = NSButton(title: "삭제", target: self, action: #selector(deleteCharacter(_:))); delete.tag = index; delete.isEnabled = !row.builtin
            addButtons[row.id] = plus; removeButtons[row.id] = minus; deleteButtons[row.id] = delete
            let line = NSStackView(views: [image, labels, count, plus, minus, delete]); line.spacing = 12
            stack.addArrangedSubview(line)
            let separator = NSBox(); separator.boxType = .separator; stack.addArrangedSubview(separator)
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        document.layoutSubtreeIfNeeded(); scroll.contentView.scroll(to: previousScroll); scroll.reflectScrolledClipView(scroll.contentView)
    }
    @objc private func add(_ sender: NSButton) { onAdd?(rows[sender.tag].id) }
    @objc private func remove(_ sender: NSButton) { onRemove?(rows[sender.tag].id) }
    @objc private func deleteCharacter(_ sender: NSButton) { let row = rows[sender.tag]; if !row.builtin { onDelete?(row.id) } }
    @objc private func createCharacter() { onCreate?() }
    @objc private func done() { close() }
    func windowWillClose(_ notification: Notification) { onClosed?() }
}

private final class FlippedLibraryView: NSView { override var isFlipped: Bool { true } }
