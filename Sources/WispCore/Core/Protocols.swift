import Foundation

struct RecordingResult {
    let samples: [Float]
    let duration: TimeInterval
}

protocol AudioServicing: AnyObject {
    func startRecording(onLevel: @escaping (AudioLevel) -> Void) throws
    /// 녹음을 멈추고 캡처된 샘플을 반환한다. 전사는 메모리 샘플로 하므로
    /// 디스크에 wav를 남기지 않는다.
    func stopRecording() throws -> RecordingResult
    func cancelRecording()
}

protocol Transcribing: Actor {
    /// prompt: whisper initial_prompt(인식 힌트, 빈 문자열이면 미사용).
    /// translate: 켜면 영어로 번역(transcribe가 아닌 translate task).
    func transcribe(samples: [Float], language: String, prompt: String, translate: Bool) async throws -> String
}

extension Transcribing {
    /// 힌트·번역 없이 부르는 기존 호출부용 편의 오버로드.
    func transcribe(samples: [Float], language: String) async throws -> String {
        try await transcribe(samples: samples, language: language, prompt: "", translate: false)
    }
}

struct PostProcessOutcome: Equatable {
    let finalText: String
    let llmOutput: String?
    let llmSucceeded: Bool
    let llmSeconds: Double
}

/// 녹음 시작 시점에 캡처한 주변 컨텍스트. 모드별 토글이 켜져 있으면 LLM 후처리
/// 프롬프트에 참고로 주입된다(선택 텍스트·클립보드를 문맥으로 활용).
struct DictationContext: Equatable {
    /// 활성 앱에서 현재 선택(하이라이트)된 텍스트. 접근성 API로 읽으며 없으면 nil.
    var selectedText: String?
    /// 현재 클립보드의 문자열 내용.
    var clipboardText: String?

    init(selectedText: String? = nil, clipboardText: String? = nil) {
        self.selectedText = selectedText
        self.clipboardText = clipboardText
    }
}

protocol PostProcessing {
    func process(transcript: String, mode: Mode, context: DictationContext) async -> PostProcessOutcome
}

extension PostProcessing {
    /// 컨텍스트 없이 부르는 기존 호출부용 편의 오버로드.
    func process(transcript: String, mode: Mode) async -> PostProcessOutcome {
        await process(transcript: transcript, mode: mode, context: DictationContext())
    }
}

enum PasteResult: Equatable {
    case pasted
    case clipboardOnly
    /// 자동 붙여넣기는 켜져 있으나 손쉬운 사용 권한이 없어 ⌘V를 주입하지 못함.
    case needsAccessibility
}

protocol Pasting {
    @discardableResult
    @MainActor func paste(_ text: String) -> PasteResult
}

/// 녹음 파이프라인의 부수효과(미디어 일시정지/음소거/볼륨·사운드 피드백) 훅.
/// RecordingController는 시점만 알리고, 무엇을 할지는 구현체가 결정한다.
@MainActor
protocol RecordingEffects {
    /// 녹음 시작 직후 — 시작음 + 모드별 미디어/오디오 억제.
    func onRecordingStart(mode: Mode)
    /// 마이크 종료 직후(성공·취소 공통) — 미디어 재개 + 볼륨 복원. 멱등.
    func onRecordingEnd()
    /// 처리 완료(.finished) 시 — 완료음.
    func onComplete()
}

/// 기본 no-op — 테스트와 효과 비활성 환경용.
/// init이 nonisolated여야 RecordingController.init의 기본 인자로 평가 가능.
struct NoopRecordingEffects: RecordingEffects {
    nonisolated init() {}
    func onRecordingStart(mode: Mode) {}
    func onRecordingEnd() {}
    func onComplete() {}
}

protocol HistoryStoring {
    func save(_ record: DictationRecord) throws
    func fetchLatest() throws -> DictationRecord?
    /// 최신순 페이지 조회. query는 transcript/llmOutput LIKE 검색,
    /// before는 keyset 페이지네이션 커서 (이 시각보다 오래된 것만).
    func fetchPage(query: String?, before: Date?, limit: Int) throws -> [DictationRecord]
    /// 행 삭제 (없는 id는 무시).
    func delete(id: String) throws
    /// date 이전 행 일괄 삭제.
    func purge(olderThan date: Date) throws
}
