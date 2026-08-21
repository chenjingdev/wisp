import Foundation

struct WispConfig: Codable, Equatable {
    var hotkeyKeyCode: UInt32 = 49        // Space
    var hotkeyModifiers: UInt32 = 2048    // Carbon optionKey
    /// 단독 보조키 핫키 ("control"/"option"/"command"/"shift"/"function").
    /// 설정되면 keyCode+modifiers 콤보 대신 이 보조키 단독 누름을 사용한다.
    var hotkeyBareModifier: String? = "control"
    var pushToTalkThreshold: Double = 0.4
    var activeModeId: String = "dictation"
    var codexBinaryPath: String = "/opt/homebrew/bin/codex"
    var codexModel: String = "gpt-5.3-codex-spark"  // Task 14에서 확정
    var llmTimeoutSeconds: Double = 10
    /// 히스토리 자동 정리 보관 일수. nil이면 끔. 기록과 wav를 함께 삭제한다.
    var autoCleanupDays: Int? = nil
    /// 자동 붙여넣기(⌘V 주입). 끄면 결과를 클립보드에만 남긴다.
    var autoPaste: Bool = true
    /// 붙여넣기 후 직전 클립보드 내용을 복원한다.
    var restoreClipboard: Bool = false
    /// 녹음 시작/완료 사운드 피드백.
    var soundFeedback: Bool = true
    /// 프리셋(모드) 빠른 전환 핫키(Control+1…9) 활성화.
    var presetHotkeysEnabled: Bool = true
    /// 받아쓰기 인식 힌트(whisper initial_prompt). 고유명사·전문용어를 적어두면
    /// 인식 정확도가 올라간다. 모든 모드에 공통 적용.
    var vocabulary: String = ""
    /// 전사 후·출력 전에 적용하는 결정적 단어 교체 규칙.
    var replacements: [ReplacementRule] = []
    /// 자동 붙여넣기 방식: 클립보드+⌘V(.clipboard) vs 문자별 키 입력(.keystroke).
    /// 붙여넣기가 막히는 보안 입력 필드·일부 Electron 앱은 .keystroke가 필요하다.
    var pasteMethod: PasteMethod = .clipboard
    /// 트랙패드 멀티터치 트리거 손가락 수(3/4/5). nil이면 끔. 키보드 단축키와 병행.
    var trackpadFingerCount: Int? = nil
    /// 활성 whisper 모델 id(ModelCatalog 참조). 모델 파일 경로가 여기서 파생된다.
    /// 알 수 없는 id면 런타임에 기본 모델로 폴백한다.
    var whisperModelId: String = ModelCatalog.defaultModelId
    /// 무음 게이트 감도 — 녹음의 peak 진폭(정규화 [-1,1])이 이 값 미만이면 발화 없음으로
    /// 보고 전사를 건너뛴다(whisper의 "Thank you" 무음 환각 방지). 낮을수록 민감(작은
    /// 소리도 받아쓰기), 높을수록 둔감(또렷한 발화만). 마이크 게인에 맞춰 조절한다.
    var speechPeakThreshold: Float = AudioMath.speechPeakThreshold
}

extension WispConfig {
    /// 누락 키는 기본값으로 채우는 관대한 디코더. 신규 필드를 추가해도 구버전
    /// config.json이 디코딩에 실패해 기존 설정이 통째로 리셋되는 일을 막는다
    /// (합성 Codable은 키가 하나만 없어도 전체 디코딩이 실패한다).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var v = WispConfig()
        v.hotkeyKeyCode = try c.decodeIfPresent(UInt32.self, forKey: .hotkeyKeyCode) ?? v.hotkeyKeyCode
        v.hotkeyModifiers = try c.decodeIfPresent(UInt32.self, forKey: .hotkeyModifiers) ?? v.hotkeyModifiers
        v.hotkeyBareModifier = try c.decodeIfPresent(String.self, forKey: .hotkeyBareModifier) ?? v.hotkeyBareModifier
        v.pushToTalkThreshold = try c.decodeIfPresent(Double.self, forKey: .pushToTalkThreshold) ?? v.pushToTalkThreshold
        v.activeModeId = try c.decodeIfPresent(String.self, forKey: .activeModeId) ?? v.activeModeId
        v.codexBinaryPath = try c.decodeIfPresent(String.self, forKey: .codexBinaryPath) ?? v.codexBinaryPath
        v.codexModel = try c.decodeIfPresent(String.self, forKey: .codexModel) ?? v.codexModel
        v.llmTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .llmTimeoutSeconds) ?? v.llmTimeoutSeconds
        v.autoCleanupDays = try c.decodeIfPresent(Int.self, forKey: .autoCleanupDays) ?? v.autoCleanupDays
        v.autoPaste = try c.decodeIfPresent(Bool.self, forKey: .autoPaste) ?? v.autoPaste
        v.restoreClipboard = try c.decodeIfPresent(Bool.self, forKey: .restoreClipboard) ?? v.restoreClipboard
        v.soundFeedback = try c.decodeIfPresent(Bool.self, forKey: .soundFeedback) ?? v.soundFeedback
        v.presetHotkeysEnabled = try c.decodeIfPresent(Bool.self, forKey: .presetHotkeysEnabled) ?? v.presetHotkeysEnabled
        v.vocabulary = try c.decodeIfPresent(String.self, forKey: .vocabulary) ?? v.vocabulary
        v.replacements = try c.decodeIfPresent([ReplacementRule].self, forKey: .replacements) ?? v.replacements
        v.pasteMethod = try c.decodeIfPresent(PasteMethod.self, forKey: .pasteMethod) ?? v.pasteMethod
        v.trackpadFingerCount = try c.decodeIfPresent(Int.self, forKey: .trackpadFingerCount) ?? v.trackpadFingerCount
        v.whisperModelId = try c.decodeIfPresent(String.self, forKey: .whisperModelId) ?? v.whisperModelId
        v.speechPeakThreshold = try c.decodeIfPresent(Float.self, forKey: .speechPeakThreshold) ?? v.speechPeakThreshold
        self = v
    }
}

final class ConfigStore {
    private let url: URL

    init(url: URL = AppPaths.configURL) {
        self.url = url
    }

    func load() -> WispConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(WispConfig.self, from: data)
        else { return WispConfig() }
        return config
    }

    func save(_ config: WispConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url, options: .atomic)
    }
}
