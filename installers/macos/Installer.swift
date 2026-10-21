import AppKit

private let appID = "local.desktopdog.idle"
private let appName = "바탕화면 강아지.app"

private enum InstallError: LocalizedError {
    case invalidApp, occupiedDestination
    var errorDescription: String? {
        switch self {
        case .invalidApp: return "설치할 앱이 손상되었습니다. 배포 파일을 다시 다운로드해 주세요."
        case .occupiedDestination: return "설치 위치에 다른 파일 또는 연결이 있습니다. ~/Applications/바탕화면 강아지.app을 확인해 주세요."
        }
    }
}

// The only write target is the app itself. Character libraries, preferences and
// Keychain items are deliberately outside this transaction.
private func install(payload: URL, destination: URL) throws {
    let fm = FileManager.default
    func validApp(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        return info["CFBundleIdentifier"] as? String == appID
    }
    guard validApp(payload) else { throw InstallError.invalidApp }
    let exists = fm.fileExists(atPath: destination.path)
    let isLink = (try? fm.attributesOfItem(atPath: destination.path)[.type]) as? FileAttributeType == .typeSymbolicLink
    guard !isLink, !exists || validApp(destination) else { throw InstallError.occupiedDestination }
    let parent = destination.deletingLastPathComponent()
    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
    let staged = parent.appendingPathComponent(".DesktopCharacter-stage-\(UUID().uuidString).app")
    let backup = parent.appendingPathComponent(".DesktopCharacter-backup-\(UUID().uuidString).app")
    defer { try? fm.removeItem(at: staged) }
    try fm.copyItem(at: payload, to: staged)
    if exists { try fm.moveItem(at: destination, to: backup) }
    do {
        try fm.moveItem(at: staged, to: destination)
    } catch {
        if exists { try? fm.moveItem(at: backup, to: destination) }
        throw error
    }
    if exists { try? fm.removeItem(at: backup) }
}

private func selfTest() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("DesktopCharacter-installer-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let fixture = root.appendingPathComponent("payload.app")
    try fm.createDirectory(at: fixture.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": appID], format: .xml, options: 0)
    try plist.write(to: fixture.appendingPathComponent("Contents/Info.plist"))
    let marker = fixture.appendingPathComponent("Contents/version")
    try Data("one".utf8).write(to: marker)
    let target = root.appendingPathComponent("Applications/\(appName)")
    try install(payload: fixture, destination: target)
    let first = try String(contentsOf: target.appendingPathComponent("Contents/version"), encoding: .utf8)
    guard first == "one" else { fatalError("first install mismatch") }
    try Data("two".utf8).write(to: marker)
    try install(payload: fixture, destination: target)
    let updated = try String(contentsOf: target.appendingPathComponent("Contents/version"), encoding: .utf8)
    guard updated == "two" else { fatalError("update mismatch") }
    let unrelated = root.appendingPathComponent("unrelated.app")
    try Data("keep".utf8).write(to: unrelated)
    do { try install(payload: fixture, destination: unrelated); fatalError("overwrote unrelated file") }
    catch InstallError.occupiedDestination { }
    let kept = try String(contentsOf: unrelated, encoding: .utf8)
    guard kept == "keep" else { fatalError("unrelated file changed") }
    let link = root.appendingPathComponent("linked.app")
    try fm.createSymbolicLink(at: link, withDestinationURL: target)
    do { try install(payload: fixture, destination: link); fatalError("overwrote symlink") }
    catch InstallError.occupiedDestination { }
    let invalid = root.appendingPathComponent("invalid.app")
    do { try install(payload: invalid, destination: target); fatalError("accepted invalid payload") }
    catch InstallError.invalidApp { }
    print("PASS: installer first install, update, unrelated-file/symlink protection and invalid payload")
}

@main
private struct Installer {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--self-test") {
            do { try selfTest() } catch { fputs("Installer check failed: \(error)\n", stderr); exit(1) }
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        let welcome = NSAlert()
        welcome.messageText = "바탕화면 친구 설치"
        welcome.informativeText = "사용자 응용 프로그램 폴더(~/Applications)에 설치하고 바로 실행합니다.\n\n처음 실행하면 강아지 한 마리가 나타납니다. 업데이트 시 캐릭터와 API 설정을 유지합니다.\n\n관리자 권한이나 로그인 시 자동 실행 설정은 필요하지 않습니다."
        welcome.addButton(withTitle: "설치하고 실행")
        welcome.addButton(withTitle: "취소")
        guard welcome.runModal() == .alertFirstButtonReturn else { return }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: appID).isEmpty else {
            let alert = NSAlert()
            alert.messageText = "실행 중인 바탕화면 친구를 종료해 주세요"
            alert.informativeText = "앱 메뉴의 ‘모두 종료’를 선택한 뒤 설치 파일을 다시 열어 주세요."
            alert.runModal()
            return
        }
        guard let payload = Bundle.main.resourceURL?.appendingPathComponent(appName) else { return }
        let destination = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications").appendingPathComponent(appName)
        do {
            try install(payload: payload, destination: destination)
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: destination, configuration: config) { _, error in
                Task { @MainActor in
                    if let error {
                        let alert = NSAlert()
                        alert.messageText = "설치는 완료되었습니다"
                        alert.informativeText = "앱 실행: \(destination.path)\n\(error.localizedDescription)"
                        alert.runModal()
                    }
                    app.terminate(nil)
                }
            }
            app.run()
        } catch {
            let alert = NSAlert()
            alert.messageText = "설치하지 못했습니다"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
