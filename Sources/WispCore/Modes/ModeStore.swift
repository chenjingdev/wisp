import Foundation

public struct Mode: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var prompt: String
    public var llmEnabled: Bool
    public var language: String   // "auto" | "ko" | "en" ...
    /// 녹음 중 시스템 미디어/오디오 처리. 구버전 모드 파일엔 없어 기본값 .pause.
    public var mediaBehavior: MediaBehavior = .pause
    /// 켜면 whisper가 전사와 동시에 영어로 번역한다(translate task). 기본 false.
    public var translateToEnglish: Bool = false
    /// LLM 후처리 시 현재 선택된 텍스트를 컨텍스트로 주입. 기본 false.
    public var useSelectedText: Bool = false
    /// LLM 후처리 시 클립보드 내용을 컨텍스트로 주입. 기본 false.
    public var useClipboardContext: Bool = false

    public init(id: String, name: String, prompt: String, llmEnabled: Bool,
                language: String, mediaBehavior: MediaBehavior = .pause,
                translateToEnglish: Bool = false,
                useSelectedText: Bool = false,
                useClipboardContext: Bool = false) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.llmEnabled = llmEnabled
        self.language = language
        self.mediaBehavior = mediaBehavior
        self.translateToEnglish = translateToEnglish
        self.useSelectedText = useSelectedText
        self.useClipboardContext = useClipboardContext
    }

    public static let defaults: [Mode] = [
        Mode(id: "dictation", name: "받아쓰기", prompt: "", llmEnabled: false, language: "auto"),
        Mode(
            id: "message", name: "메시지",
            prompt: "받아쓰기 원문을 메신저로 보낼 자연스러운 한국어 문장으로 다듬는다. "
                + "군말(어, 음, 그)과 반복을 제거하고 문장부호를 정리한다. 의미를 추가하거나 빼지 않는다.",
            llmEnabled: true, language: "auto"
        ),
        Mode(
            id: "email", name: "이메일",
            prompt: "받아쓰기 원문을 정중한 비즈니스 이메일 본문으로 다듬는다. "
                + "존댓말을 사용하고 문단을 적절히 나눈다. 의미를 추가하거나 빼지 않는다.",
            llmEnabled: true, language: "auto"
        ),
    ]
}

extension Mode {
    /// 누락 키는 기본값으로 채우는 관대한 디코더 — 구버전 모드 파일(mediaBehavior
    /// 없음)이 디코딩 실패하지 않도록 한다.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
            prompt: try c.decodeIfPresent(String.self, forKey: .prompt) ?? "",
            llmEnabled: try c.decodeIfPresent(Bool.self, forKey: .llmEnabled) ?? false,
            language: try c.decodeIfPresent(String.self, forKey: .language) ?? "auto",
            mediaBehavior: try c.decodeIfPresent(MediaBehavior.self, forKey: .mediaBehavior) ?? .pause,
            translateToEnglish: try c.decodeIfPresent(Bool.self, forKey: .translateToEnglish) ?? false,
            useSelectedText: try c.decodeIfPresent(Bool.self, forKey: .useSelectedText) ?? false,
            useClipboardContext: try c.decodeIfPresent(Bool.self, forKey: .useClipboardContext) ?? false
        )
    }
}

final class ModeStore {
    private let directory: URL

    init(directory: URL = AppPaths.modes) {
        self.directory = directory
    }

    /// 모드 디렉터리가 비어 있을 때만 기본 3종을 시딩한다. 한 번이라도 모드가 있으면
    /// (사용자가 기본 모드를 지웠더라도) 다시 만들지 않는다 — 기본 모드도 영구 삭제 가능.
    /// 전부 지워 비면 다음 실행 때 기본 3종으로 복구된다(모드 0개 방지).
    func seedDefaultsIfNeeded() throws {
        let hasAny = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
            ?? []).contains { $0.pathExtension == "json" }
        guard !hasAny else { return }
        for mode in Mode.defaults { try save(mode) }
    }

    func loadAll() throws -> [Mode] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let canonical = Mode.defaults.map(\.id)
        return try files.map { try JSONDecoder().decode(Mode.self, from: Data(contentsOf: $0)) }
            .sorted { a, b in
                let ia = canonical.firstIndex(of: a.id) ?? Int.max
                let ib = canonical.firstIndex(of: b.id) ?? Int.max
                return ia == ib ? a.name < b.name : ia < ib
            }
    }

    func mode(id: String) throws -> Mode? {
        let fileURL = url(for: id)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(Mode.self, from: Data(contentsOf: fileURL))
    }

    func save(_ mode: Mode) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(mode).write(to: url(for: mode.id), options: .atomic)
    }

    /// 새 커스텀 모드를 만들어 저장하고 반환한다.
    func create() throws -> Mode {
        let mode = Mode(
            id: "custom-\(UUID().uuidString.prefix(8).lowercased())",
            name: "새 모드", prompt: "", llmEnabled: true, language: "auto"
        )
        try save(mode)
        return mode
    }

    /// 모드 파일 삭제. 모드는 전부 동등(이름·프롬프트 묶음)하게 다루므로 기본 모드도
    /// 삭제할 수 있다. 마지막 1개 보호는 호출부(UI)에서 담당한다.
    func delete(id: String) throws {
        try FileManager.default.removeItem(at: url(for: id))
    }

    private func url(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }
}
