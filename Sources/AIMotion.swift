import Foundation
import Security
import ImageIO
import CoreGraphics

struct AIProvider: Codable, Equatable {
    let id: String
    static let names = ["openai": "OpenAI (ChatGPT 이미지)", "gemini": "Google Gemini", "anthropic": "Anthropic Claude (설명 보조)"]
    static let roots = ["openai": "https://api.openai.com/v1", "gemini": "https://generativelanguage.googleapis.com/v1beta", "anthropic": "https://api.anthropic.com/v1"]
    static let keyPages = ["openai": "https://platform.openai.com/api-keys", "gemini": "https://aistudio.google.com/api-keys", "anthropic": "https://platform.claude.com/settings/keys"]
}

struct AIConnection: Codable, Equatable {
    var id = UUID().uuidString.lowercased()
    var provider: String
    var name: String
    var model: String
    var verified_at: Double? = nil
    var imageCapable: Bool { provider == "openai" || provider == "gemini" }
    func validate() throws {
        guard UUID(uuidString: id) != nil, AIProvider.names[provider] != nil,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 40,
              model.range(of: "^[A-Za-z0-9._-]{1,120}$", options: .regularExpression) != nil else {
            throw AIError.message("API 종류·이름(1~40자)·모델 ID를 확인하세요.")
        }
        if provider == "openai" && !(model.hasPrefix("gpt-image-") || model == "chatgpt-image-latest") {
            throw AIError.message("OpenAI는 이미지 편집 모델 ID를 입력하세요. 채팅 모델은 시트를 만들 수 없습니다.")
        }
        if provider == "gemini" && !(model.hasPrefix("gemini-") && (model.contains("image") || model.contains("nano-banana"))) {
            throw AIError.message("Gemini는 이미지 생성 모델 ID를 입력하세요.")
        }
        if provider == "anthropic" && !model.hasPrefix("claude-") { throw AIError.message("Claude 모델 ID를 입력하세요.") }
    }
}

enum AIError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    static func key(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 4096, !value.contains(where: { $0.isWhitespace }) else {
            throw message("공백이나 줄바꿈 없이 개인 API 키를 입력하세요.")
        }
        return value
    }
    static func http(_ status: Int) -> AIError {
        let text: String
        switch status {
        case 400: text = "모델이 요청을 거절했습니다. 이미지 생성 지원·입력 크기·필터를 확인하세요."
        case 401: text = "API 키 인증에 실패했습니다."
        case 403: text = "모델 사용 권한이나 계정 인증을 확인하세요."
        case 404: text = "모델을 찾지 못했습니다. 모델 ID와 계정 사용 권한을 확인하세요."
        case 429: text = "호출 한도 또는 API 잔액을 확인하고 나중에 다시 시도하세요."
        default: text = "API 요청 실패 (HTTP \(status)). 자동 재시도하지 않았습니다."
        }
        return .message(text)
    }
}

protocol AISecretStore {
    func get(_ id: String) throws -> String
    func put(_ id: String, key: String) throws
    func delete(_ id: String) throws
}

final class AIKeychain: AISecretStore {
    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.desktopcharacter.ai", kSecAttrAccount as String: id]
    }
    func get(_ id: String) throws -> String {
        var value = query(id)
        value[kSecReturnData as String] = true
        value[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(value as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw AIError.message("키체인의 API 키를 읽지 못했습니다. 잠금 상태를 확인하거나 키를 다시 입력하세요.")
        }
        return key
    }
    func put(_ id: String, key: String) throws {
        let data = Data(try AIError.key(key).utf8)
        let status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var value = query(id)
            value[kSecValueData as String] = data
            guard SecItemAdd(value as CFDictionary, nil) == errSecSuccess else { throw AIError.message("API 키를 키체인에 저장하지 못했습니다.") }
        } else if status != errSecSuccess { throw AIError.message("API 키를 키체인에 저장하지 못했습니다.") }
    }
    func delete(_ id: String) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AIError.message("키체인에서 API 키를 삭제하지 못했습니다.") }
    }
}

final class AIConnectionStore {
    struct State: Codable {
        var connections: [AIConnection] = []
        var renderer_id: String? = nil
        var director_id: String? = nil
    }
    let url: URL
    let secrets: AISecretStore
    var state: State
    init(url: URL, secrets: AISecretStore = AIKeychain()) {
        self.url = url; self.secrets = secrets
        state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: url))) ?? State()
        state.connections = state.connections.filter { (try? $0.validate()) != nil }
    }
    func persist() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
    func save(_ profile: AIConnection, key: String) throws {
        try profile.validate()
        let old = state
        let oldKey = try? secrets.get(profile.id)
        try secrets.put(profile.id, key: key)
        state.connections.removeAll { $0.id == profile.id }; state.connections.append(profile)
        do { try persist() }
        catch {
            state = old
            if let oldKey { try? secrets.put(profile.id, key: oldKey) } else { try? secrets.delete(profile.id) }
            throw AIError.message("API 설정을 저장하지 못했습니다. 저장 공간을 확인하세요.")
        }
    }
    func delete(_ profile: AIConnection) throws {
        let old = state
        state.connections.removeAll { $0.id == profile.id }
        do { try persist(); try secrets.delete(profile.id) }
        catch { state = old; try? persist(); throw error }
    }
}

struct AIMotionCatalog: Decodable {
    var defaults: [String: String]
    var instructions: String
    var motions: [String: String]
    static func load(root: URL? = nil) throws -> Self {
        let url = (root ?? Bundle.main.resourceURL!).appendingPathComponent("ai/motions.json")
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
    func prompt(slot: CharacterSlot, layout: String, background: String) throws -> String {
        let key = slot == .leap ? "leap_" + layout : slot.rawValue
        guard let motion = motions[key] else { throw AIError.message("이 동작의 생성 안내를 찾지 못했습니다.") }
        return instructions + "\nGrid: exactly \(slot.columns) columns x \(slot.rows) rows, \(slot.columns * slot.rows) poses.\n" + motion + "\n" + background
    }
}

protocol AITransport {
    func send(_ request: URLRequest) async throws -> Data
}

final class AIURLTransport: NSObject, AITransport, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func send(_ request: URLRequest) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = request.timeoutInterval; config.timeoutIntervalForResource = 300
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw AIError.message("API 응답 형식이 올바르지 않습니다.") }
            guard (200..<300).contains(http.statusCode) else { throw AIError.http(http.statusCode) }
            guard data.count <= 64 * 1024 * 1024 else { throw AIError.message("API 응답이 너무 큽니다.") }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as AIError { throw error }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw AIError.message("API에 연결하지 못했거나 시간이 초과됐습니다. 네트워크를 확인하세요.")
        }
    }
}

struct AIMotionService {
    var transport: AITransport = AIURLTransport()
    static func request(profile: AIConnection, key: String, path: String, body: [String: Any]? = nil) throws -> URLRequest {
        try profile.validate()
        let key = try AIError.key(key)
        var request = URLRequest(url: URL(string: AIProvider.roots[profile.provider]! + path)!)
        request.timeoutInterval = body == nil ? 30 : 240
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch profile.provider {
        case "openai": request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        case "gemini": request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        default:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        if let body { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return request
    }
    static func object(_ data: Data) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError.message("API 응답 형식이 올바르지 않습니다.") }
        return result
    }
    func verify(_ profile: AIConnection, key: String) async throws {
        let result = try Self.object(await transport.send(Self.request(profile: profile, key: key, path: "/models/" + profile.model)))
        guard result["id"] as? String != nil || result["name"] as? String != nil else { throw AIError.message("모델 정보가 없는 응답입니다. 검증을 완료하지 못했습니다.") }
        if profile.provider == "gemini", !(result["supportedGenerationMethods"] as? [String] ?? []).contains("generateContent") {
            throw AIError.message("이 모델은 이미지 입력 생성 API를 지원하지 않습니다.")
        }
        if profile.provider == "anthropic", let capabilities = result["capabilities"] as? [String: Any],
           let input = capabilities["image_input"] as? [String: Any], input["supported"] as? Bool == false {
            throw AIError.message("이 Claude 모델은 이미지 입력을 지원하지 않습니다.")
        }
    }
    static func generationRequest(profile: AIConnection, key: String, prompt: String, inputs: [Data], slot: CharacterSlot) throws -> URLRequest {
        guard inputs.count == 2 else { throw AIError.message("정지 이미지와 동작 예시가 모두 필요합니다.") }
        let encoded = inputs.map { $0.base64EncodedString() }
        if profile.provider == "openai" {
            let size = profile.model.hasPrefix("gpt-image-1") || profile.model.hasPrefix("chatgpt-image") ? "1536x1024" : (slot == .gaze ? "1536x512" : "1536x768")
            return try request(profile: profile, key: key, path: "/images/edits", body: ["model": profile.model, "prompt": prompt,
                "images": encoded.map { ["image_url": "data:image/png;base64," + $0] }, "n": 1,
                "quality": "medium", "background": "transparent", "output_format": "png", "size": size])
        }
        if profile.provider == "gemini" {
            let parts: [[String: Any]] = [["text": prompt]] + encoded.map { ["inlineData": ["mimeType": "image/png", "data": $0]] }
            return try request(profile: profile, key: key, path: "/models/" + profile.model + ":generateContent", body: [
                "contents": [["role": "user", "parts": parts]], "generationConfig": ["responseModalities": ["TEXT", "IMAGE"],
                "imageConfig": ["aspectRatio": slot == .gaze ? "21:9" : "16:9"]]])
        }
        var parts: [[String: Any]] = encoded.map { ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": $0]] }
        parts.append(["type": "text", "text": "Analyze Image 1 identity and Image 2 motion. Return only a concise English animation brief, no code, max 180 words. Honor these fixed requirements:\n" + prompt])
        return try request(profile: profile, key: key, path: "/messages", body: ["model": profile.model, "max_tokens": 512, "messages": [["role": "user", "content": parts]]])
    }
    static func imageData(_ value: [String: Any], provider: String) throws -> Data {
        var encoded: String?
        if provider == "openai" { encoded = (value["data"] as? [[String: Any]])?.first?["b64_json"] as? String }
        else if let candidate = (value["candidates"] as? [[String: Any]])?.first,
                let content = candidate["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]] {
            for part in parts where part["thought"] as? Bool != true {
                if let image = (part["inlineData"] ?? part["inline_data"]) as? [String: Any],
                   let mime = (image["mimeType"] ?? image["mime_type"]) as? String, mime.hasPrefix("image/") {
                    encoded = image["data"] as? String; break
                }
            }
        }
        guard let encoded, let data = Data(base64Encoded: encoded), !data.isEmpty, data.count <= 32 * 1024 * 1024 else {
            throw AIError.message("이미지가 반환되지 않았습니다. 모델 지원·정책 필터를 확인하세요. 기존 이미지는 유지했습니다.")
        }
        return data
    }
    func generate(profile: AIConnection, key: String, slot: CharacterSlot, layout: String, standing: URL, example: URL,
                  destination: URL, mirror: Bool, director: AIConnection?, directorKey: String?) async throws -> URL {
        guard profile.imageCapable, profile.verified_at != nil else { throw AIError.message("이미지 생성 API를 추가하고 먼저 검증하세요.") }
        try Task.checkCancellation()
        let inputs = try [AIImage.input(standing), AIImage.input(example, mirror: mirror)]
        let chroma = profile.provider == "gemini" ? try AIImage.chroma(inputs[0]) : nil
        let background: String
        if let chroma { background = String(format: "Use ONLY a perfectly uniform solid background color #%02X%02X%02X. No shadows, texture, gradient or checkerboard. This background will be removed locally.", chroma[0], chroma[1], chroma[2]) }
        else { background = "Use a truly transparent alpha background, not a checkerboard or solid color." }
        var prompt = try AIMotionCatalog.load().prompt(slot: slot, layout: layout, background: background)
        if let director {
            guard director.provider == "anthropic", director.verified_at != nil, let directorKey else { throw AIError.message("설명 보조 API는 검증된 Claude를 선택하세요.") }
            try Task.checkCancellation()
            let request = try Self.generationRequest(profile: director, key: directorKey, prompt: prompt, inputs: inputs, slot: slot)
            let response = try Self.object(await transport.send(request))
            let brief = (response["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
            guard !brief.isEmpty else { throw AIError.message("Claude가 모션 설명을 반환하지 않았습니다.") }
            prompt += "\nOptional animation observations (fixed layout/identity rules above take priority):\n" + String(brief.prefix(2400))
        }
        try Task.checkCancellation()
        let request = try Self.generationRequest(profile: profile, key: key, prompt: prompt, inputs: inputs, slot: slot)
        let response = try Self.object(await transport.send(request))
        try Task.checkCancellation()
        try AIImage.prepare(Self.imageData(response, provider: profile.provider), slot: slot, destination: destination, chroma: chroma)
        try Task.checkCancellation()
        return destination
    }
}

enum AIImage {
    static func load(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= 8192, h <= 8192, w * h <= 16_777_216,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw AIError.message("API가 유효한 크기의 이미지를 반환하지 않았습니다.") }
        return image
    }
    static func context(_ width: Int, _ height: Int) throws -> CGContext {
        guard let value = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw AIError.message("이미지를 처리할 메모리가 부족합니다.") }
        value.interpolationQuality = .none
        return value
    }
    static func png(_ image: CGImage) throws -> Data {
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, "public.png" as CFString, 1, nil) else { throw AIError.message("PNG를 만들지 못했습니다.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw AIError.message("PNG를 저장하지 못했습니다.") }
        return result as Data
    }
    static func input(_ url: URL, mirror: Bool = false) throws -> Data {
        let image = try load(Data(contentsOf: url))
        let scale = min(1, 1536 / CGFloat(max(image.width, image.height)))
        let w = max(1, Int(CGFloat(image.width) * scale)), h = max(1, Int(CGFloat(image.height) * scale))
        let ctx = try context(w, h)
        if mirror { ctx.translateBy(x: CGFloat(w), y: 0); ctx.scaleBy(x: -1, y: 1) }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let result = try png(ctx.makeImage()!)
        guard result.count <= 4 * 1024 * 1024 else { throw AIError.message("API 전송용 PNG가 너무 큽니다. 원본 크기를 줄여 주세요.") }
        return result
    }
    static func chroma(_ data: Data) throws -> [Int] {
        let image = try load(data), ctx = try context(96, 96)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 96, height: 96))
        let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let palette = [[255, 0, 255], [0, 255, 0], [0, 255, 255], [255, 128, 0]]
        func score(_ color: [Int]) -> Int {
            var value = Int.max
            for i in stride(from: 0, to: 96 * 96 * 4, by: 4) where bytes[i+3] > 32 {
                var sum = 0
                for c in 0..<3 { let d = Int(bytes[i+c]) - color[c]; sum += d*d }
                value = min(value, sum)
            }
            return value
        }
        return palette.max { score($0) < score($1) }!
    }
    static func prepare(_ data: Data, slot: CharacterSlot, destination: URL, chroma: [Int]?) throws {
        let source = try load(data)
        let w = source.width - source.width % slot.columns, h = source.height - source.height % slot.rows
        guard w >= slot.columns * 8, h >= slot.rows * 8,
              let cropped = source.cropping(to: CGRect(x: 0, y: 0, width: w, height: h)) else { throw AIError.message("생성된 이미지의 격자 크기가 올바르지 않습니다.") }
        let ctx = try context(w, h)
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        if let chroma {
            let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
            let cw = w / slot.columns, ch = h / slot.rows
            for row in 0..<slot.rows { for col in 0..<slot.columns {
                let x0 = col*cw, y0 = row*ch
                var seen = [UInt8](repeating: 0, count: cw*ch), queue: [Int] = []
                for x in 0..<cw { queue.append(x); queue.append((ch-1)*cw+x) }
                for y in 0..<ch { queue.append(y*cw); queue.append(y*cw+cw-1) }
                var cursor = 0
                while cursor < queue.count {
                    let p = queue[cursor]; cursor += 1
                    if seen[p] == 1 { continue }; seen[p] = 1
                    let x = p % cw, y = p / cw, i = ((y0+y)*w+x0+x)*4
                    var distance = 0
                    for c in 0..<3 { let d = Int(bytes[i+c]) - chroma[c]; distance += d*d }
                    if bytes[i+3] == 0 || distance <= 60*60 {
                        bytes[i] = 0; bytes[i+1] = 0; bytes[i+2] = 0; bytes[i+3] = 0
                        if x > 0 { queue.append(p-1) }; if x+1 < cw { queue.append(p+1) }
                        if y > 0 { queue.append(p-cw) }; if y+1 < ch { queue.append(p+cw) }
                    }
                }
            } }
        }
        try png(ctx.makeImage()!).write(to: destination, options: .atomic)
    }
}
