import AppKit

private final class AITestSecrets: AISecretStore {
    var values: [String: String] = [:]
    func get(_ id: String) throws -> String {
        guard let value = values[id] else { throw AIError.message("Missing test credential") }; return value
    }
    func put(_ id: String, key: String) throws { values[id] = key }
    func delete(_ id: String) throws { values.removeValue(forKey: id) }
}

private actor AITestHTTP: AITransport {
    var requests: [URLRequest] = []
    var responses: [Data]
    init(_ responses: [Data]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> Data {
        requests.append(request)
        guard !responses.isEmpty else { throw AIError.http(401) }
        return responses.removeFirst()
    }
}

@MainActor enum AIMotionChecks {
    static func run(imagesRoot: URL) async throws {
        func check(_ value: Bool, _ message: String) throws { if !value { throw AIError.message("AI 모션 검사: " + message) } }
        func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        func response(_ slot: CharacterSlot) throws -> Data {
            try json(["data": [["b64_json": try Data(contentsOf: slot.example(.puppy, in: imagesRoot)).base64EncodedString()]]])
        }
        func rejects(_ operation: () throws -> Void) throws {
            var rejected = false; do { try operation() } catch { rejected = true }
            try check(rejected, "잘못된 입력 거부")
        }
        func wait(_ predicate: () -> Bool) async throws {
            let until = Date().addingTimeInterval(15)
            while !predicate(), Date() < until { try await Task.sleep(nanoseconds: 10_000_000) }
            try check(predicate(), "생성 작업 완료 시간 초과")
        }
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("ai-check-" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let presets = try AIMotionCatalog.load(), key = "test-only-local-key"
        let inputURL = CharacterSlot.standing.example(.puppy, in: imagesRoot)
        let original = try Data(contentsOf: inputURL)
        let inputs = try [AIImage.input(inputURL), AIImage.input(CharacterSlot.walk.example(.puppy, in: imagesRoot))]
        let prompt = try presets.prompt(slot: .walk, layout: "split", background: "Transparent alpha")
        for provider in ["openai", "gemini", "anthropic"] {
            let profile = AIConnection(provider: provider, name: provider, model: presets.defaults[provider]!, verified_at: 1)
            let request = try AIMotionService.generationRequest(profile: profile, key: key, prompt: prompt, inputs: inputs, slot: .walk)
            try check(!request.url!.absoluteString.contains(key), "키는 URL에 포함하지 않음")
            let body = try AIMotionService.object(request.httpBody!)
            if provider == "openai" {
                try check(request.url?.absoluteString == "https://api.openai.com/v1/images/edits", "OpenAI 공식 호스트")
                let images = body["images"] as! [[String: String]]
                try check(images.count == 2 && images[0]["image_url"]!.hasSuffix(inputs[0].base64EncodedString()) && images[1]["image_url"]!.hasSuffix(inputs[1].base64EncodedString()), "정지 이미지와 모션 예시 전송")
            } else if provider == "gemini" {
                let parts = (body["contents"] as! [[String: Any]])[0]["parts"] as! [[String: Any]]
                try check(parts.filter { $0["inlineData"] != nil }.count == 2, "Gemini 두 이미지 입력")
            } else {
                let parts = (body["messages"] as! [[String: Any]])[0]["content"] as! [[String: Any]]
                try check(parts.filter { $0["type"] as? String == "image" }.count == 2, "Claude 두 이미지 분석 입력")
            }
            let stub = AITestHTTP([try json(["id": profile.model, "supportedGenerationMethods": ["generateContent"]])])
            try await AIMotionService(transport: stub).verify(profile, key: key)
            let requests = await stub.requests
            try check(requests.count == 1 && requests[0].httpBody == nil && requests[0].httpMethod == "GET", "검증은 모델 조회만 실행")
            var invalid = profile; invalid.model = "https://invalid.example"
            try rejects { try invalid.validate() }
        }
        try rejects { _ = try AIMotionService.imageData([:], provider: "openai") }
        try rejects { _ = try AIImage.load(Data("invalid".utf8)) }
        let renderer = AIConnection(provider: "openai", name: "테스트 이미지 API", model: presets.defaults["openai"]!, verified_at: 1)
        let director = AIConnection(provider: "anthropic", name: "테스트 보조", model: presets.defaults["anthropic"]!, verified_at: 1)
        let stub = AITestHTTP([try json(["content": [["type": "text", "text": "Use a grounded walking cycle."]]]), try response(.walk)])
        let output = folder.appendingPathComponent("result.png")
        _ = try await AIMotionService(transport: stub).generate(profile: renderer, key: key, slot: .walk, layout: "split", standing: inputURL,
            example: CharacterSlot.walk.example(.puppy, in: imagesRoot), destination: output, mirror: false, director: director, directorKey: "test-only-director")
        do { try CustomCharacterStore.validatePNG(output, slot: .walk) }
        catch { throw AIError.message("AI 응답 PNG 변환 검사: " + error.localizedDescription) }
        try check(await stub.requests.count == 2, "Claude 설명 후 이미지 생성")
        // A color-key pixel enclosed by the character must survive edge fill.
        let ctx = try AIImage.context(128, 64)
        let magenta = CGColor(colorSpace: ctx.colorSpace!, components: [1, 0, 1, 1])!
        ctx.setFillColor(magenta); ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 64))
        ctx.setFillColor(CGColor(colorSpace: ctx.colorSpace!, components: [0, 0, 1, 1])!)
        for y in 0..<2 { for x in 0..<4 { ctx.fill(CGRect(x: x*32+8, y: y*32+8, width: 16, height: 16)) } }
        ctx.setFillColor(magenta); ctx.fill(CGRect(x: 16, y: 16, width: 1, height: 1))
        try AIImage.prepare(AIImage.png(ctx.makeImage()!), slot: .walk, destination: output, chroma: [255, 0, 255])
        do { try CustomCharacterStore.validatePNG(output, slot: .walk) }
        catch { throw AIError.message("AI 단색 배경 투명화 검사: " + error.localizedDescription) }
        let cleaned = try AIImage.load(Data(contentsOf: output)), decoded = try AIImage.context(128, 64)
        decoded.draw(cleaned, in: CGRect(x: 0, y: 0, width: 128, height: 64))
        let pixels = decoded.data!.assumingMemoryBound(to: UInt8.self)
        try check(pixels[3] == 0 && pixels[(16*128+16)*4+3] == 255, "배경만 투명 처리하고 내부 색상 보존")
        let secrets = AITestSecrets(), aiStore = AIConnectionStore(url: folder.appendingPathComponent("ai-connections.json"), secrets: AITestSecrets())
        let isolatedStore = AIConnectionStore(url: folder.appendingPathComponent("isolated-ai.json"), secrets: secrets)
        try isolatedStore.save(renderer, key: key)
        try check(!(try String(contentsOf: isolatedStore.url)).contains(key), "메타데이터에 키 비노출")
        try isolatedStore.delete(renderer)
        try check(secrets.values[renderer.id] == nil, "삭제 시 키 정리")
        // Verify the actual Add / Verify UI using a fake, non-network transport.
        let manager = AIConnectionsWindow(store: aiStore)
        defer { manager.close() }
        manager.keyField.stringValue = key
        manager.service = AIMotionService(transport: AITestHTTP([try json(["id": presets.defaults["openai"]!])]))
        manager.verifyButton.performClick(nil)
        try await wait { manager.verifyButton.isEnabled }
        try check(manager.status.stringValue.contains("성공"), "API 검증 UI 결과")
        manager.addButton.performClick(nil)
        try check(aiStore.state.connections.count == 1 && aiStore.state.connections[0].verified_at != nil, "추가 버튼으로 검증 정보 저장")
        let creator = CharacterCreator(store: CustomCharacterStore(root: folder.appendingPathComponent("characters")), imagesRoot: imagesRoot,
                                       template: .puppy, aiConnections: aiStore)
        defer { creator.close() }
        creator.makeMotions([.walk])
        try check(!creator.isGenerating && creator.aiStatus.stringValue.contains("정지"), "정지 이미지 먼저 등록")
        try creator.assign(inputURL, to: .standing)
        let walk = CharacterSlot.walk.example(.puppy, in: imagesRoot)
        try creator.assign(walk, to: .walk)
        let slots = CharacterSlot.allCases.filter { $0 != .standing && $0 != .walk }
        let batch = AITestHTTP(try slots.map { try response($0) })
        creator.aiService = AIMotionService(transport: batch)
        creator.generateAllButton.performClick(nil)
        try await wait { !creator.isGenerating }
        try check(creator.files.count == 9 && creator.saveButton.isEnabled && creator.files[.walk] == walk, "전체 생성·기존 모션 건너뛰기·저장 가능")
        try check(await batch.requests.count == 7, "모션마다 한 요청·자동 재시도 없음")
        let before = creator.files
        creator.aiService = AIMotionService(transport: AITestHTTP([try response(.walk)]))
        creator.makeMotions([.walk]); try await wait { !creator.isGenerating }
        try check(creator.files[.walk] != walk && before.filter { $0.key != .walk }.allSatisfy { creator.files[$0.key] == $0.value }, "개별 모션만 교체")
        let previous = creator.files[.walk]
        creator.aiService = AIMotionService(transport: AITestHTTP([]))
        creator.makeMotions([.walk]); try await wait { !creator.isGenerating }
        try check(creator.files[.walk] == previous && creator.aiStatus.stringValue.contains("인증"), "실패해도 기존 이미지 유지")
        let cancelled = AITestHTTP([try response(.walk)])
        creator.aiService = AIMotionService(transport: cancelled)
        creator.makeMotions([.walk]); creator.cancelAIButton.performClick(nil)
        try await wait { !creator.isGenerating }
        try check(creator.files[.walk] == previous, "취소 결과 적용 방지")
        try check(try Data(contentsOf: inputURL) == original, "사용자 정지 이미지 원본 보존")
        print("PASS: AI 두 이미지 전송·모델 조회 검증·키 비노출·Claude 보조·배경 투명화·API 추가 UI·전체/개별 생성·실패 보존·취소 (외부 API 호출 없음)")
    }
}
