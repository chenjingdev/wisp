import Foundation
@testable import WispCore

private final class MockAudio: AudioServicing {
    var cancelled = false
    var failOnStart = false
    var silent = false   // true면 무음 샘플 반환(무음 게이트 검증용)

    func startRecording(onLevel: @escaping (AudioLevel) -> Void) throws {
        if failOnStart { throw WispError.audioSetupFailed }
        onLevel(AudioLevel(rms: 0.1, peak: 0.1))
    }

    func stopRecording() throws -> RecordingResult {
        let samples: [Float] = silent
            ? [Float](repeating: 0.002, count: 100)   // 노이즈 플로어 — hasSpeech false
            : [0.1, 0.2, 0.3]
        return RecordingResult(samples: samples, duration: 1.0)
    }

    func cancelRecording() { cancelled = true }
}

private actor MockTranscriber: Transcribing {
    let output: String
    var lastPrompt: String?
    var lastTranslate: Bool?
    init(output: String = "안녕하세요 테스트입니다") {
        self.output = output
    }
    func transcribe(samples: [Float], language: String, prompt: String, translate: Bool) async throws -> String {
        lastPrompt = prompt
        lastTranslate = translate
        return output
    }
}

private final class MockPostProcess: PostProcessing, @unchecked Sendable {
    let outcome: PostProcessOutcome
    var lastContext: DictationContext?
    init(outcome: PostProcessOutcome) { self.outcome = outcome }
    func process(transcript: String, mode: Mode, context: DictationContext) async -> PostProcessOutcome {
        lastContext = context
        return outcome
    }
}

private final class MockPaste: Pasting {
    var pasted: [String] = []
    var result: PasteResult = .pasted
    @MainActor func paste(_ text: String) -> PasteResult {
        pasted.append(text)
        return result
    }
}

private final class MockHistory: HistoryStoring {
    var saved: [DictationRecord] = []
    func save(_ record: DictationRecord) throws { saved.append(record) }
    func fetchLatest() throws -> DictationRecord? { saved.last }
    func fetchPage(query: String?, before: Date?, limit: Int) throws -> [DictationRecord] { saved }
    func delete(id: String) throws {}
    func purge(olderThan date: Date) throws {}
}

@MainActor
private final class MockEffects: RecordingEffects {
    var events: [String] = []
    func onRecordingStart(mode: Mode) { events.append("start:\(mode.id)") }
    func onRecordingEnd() { events.append("end") }
    func onComplete() { events.append("complete") }
}

@MainActor
private func makeController(
    audio: MockAudio = MockAudio(),
    outcome: PostProcessOutcome = PostProcessOutcome(
        finalText: "다듬어진 텍스트", llmOutput: "다듬어진 텍스트", llmSucceeded: true, llmSeconds: 0.5
    ),
    paste: MockPaste = MockPaste(),
    history: MockHistory = MockHistory(),
    effects: RecordingEffects = NoopRecordingEffects()
) -> RecordingController {
    RecordingController(
        audio: audio,
        transcription: MockTranscriber(),
        postProcess: MockPostProcess(outcome: outcome),
        paste: paste,
        history: history,
        modeProvider: { Mode.defaults[1] },
        frontmostBundleId: { "com.apple.TextEdit" },
        effects: effects
    )
}

@MainActor
func recordingControllerTests(_ t: TestRunner) async {
    await t.test("Pipeline: 해피패스 — LLM 결과 붙여넣고 히스토리 저장") {
        let paste = MockPaste()
        let history = MockHistory()
        let controller = makeController(paste: paste, history: history)

        controller.startRecording()
        try expect(controller.state == .recording, "startRecording 후 recording 상태여야 함")

        controller.stopAndProcess()
        await controller.processingTask?.value

        try expectEqual(paste.pasted, ["다듬어진 텍스트"])
        let record = try unwrap(history.saved.first)
        try expectEqual(record.transcript, "안녕하세요 테스트입니다")
        try expectEqual(record.llmOutput, "다듬어진 텍스트")
        try expect(record.llmSucceeded == true, "llmSucceeded true여야 함")
        try expectEqual(record.targetBundleId, "com.apple.TextEdit")
    }

    await t.test("Pipeline: .pasted면 lastPasteAt 기록 — 윈도우 내 취소 가능, 소비 후 불가") {
        let paste = MockPaste()   // 기본 .pasted
        let controller = makeController(paste: paste)
        try expect(controller.lastPasteAt == nil, "처음엔 nil")
        try expect(!controller.recentDictationUndoable(), "붙여넣기 전엔 취소 불가")

        controller.startRecording()
        controller.stopAndProcess()
        await controller.processingTask?.value

        let pastedAt = try unwrap(controller.lastPasteAt)
        try expectEqual(controller.lastPastedText, "다듬어진 텍스트")   // Backspace 글자 수 산정용
        try expect(controller.recentDictationUndoable(now: pastedAt.addingTimeInterval(3)),
                   "3초 내는 취소 가능")
        try expect(!controller.recentDictationUndoable(now: pastedAt.addingTimeInterval(20)),
                   "20초 후(윈도우 밖)는 취소 불가")

        controller.markDictationUndone()
        try expect(!controller.recentDictationUndoable(now: pastedAt), "소비 후엔 취소 불가")
        try expect(controller.lastPastedText == nil, "소비 후 텍스트도 nil")
    }

    await t.test("Pipeline: pasteSettleRemaining — 갓 붙여넣었으면 대기, 오래됐으면 0") {
        let paste = MockPaste()   // 기본 .pasted
        let controller = makeController(paste: paste)
        try expectEqual(controller.pasteSettleRemaining(), 0)   // 붙여넣기 전엔 대기 없음

        controller.startRecording()
        controller.stopAndProcess()
        await controller.processingTask?.value

        let pastedAt = try unwrap(controller.lastPasteAt)
        // 붙여넣은 직후(같은 시각): window(0.15) 전체가 남는다 → Return을 미뤄 터미널 race 회피.
        try expect(controller.pasteSettleRemaining(window: 0.15, now: pastedAt) == 0.15,
                   "갓 붙여넣은 직후엔 window 전체가 남아야 함")
        // 0.1초 경과: 남은 0.05초. (Date의 큰 reference 값 때문에 ~1e-7 부동소수점 오차가
        // 끼므로 1ms 허용오차로 본다 — 잔여 산정 로직만 검증.)
        let half = controller.pasteSettleRemaining(window: 0.15, now: pastedAt.addingTimeInterval(0.1))
        try expect(abs(half - 0.05) < 1e-3, "경과분만큼 줄어든 잔여여야 함")
        // window 넘김: 0 (사용자가 텍스트 보고 한참 뒤 톡 친 경우 지연 없음).
        try expectEqual(controller.pasteSettleRemaining(window: 0.15, now: pastedAt.addingTimeInterval(1)), 0)
    }

    await t.test("Pipeline: 무음이면 전사·붙여넣기·기록 없이 조용히 종료 (whisper 환각 방지)") {
        let audio = MockAudio()
        audio.silent = true
        let paste = MockPaste()
        let history = MockHistory()
        let controller = makeController(audio: audio, paste: paste, history: history)

        controller.startRecording()
        controller.stopAndProcess()
        await controller.processingTask?.value

        try expect(paste.pasted.isEmpty, "무음이면 아무것도 붙여넣지 않음")
        try expect(history.saved.isEmpty, "무음이면 히스토리에 안 남김")
        try expect(controller.lastPasteAt == nil, "무음이면 취소 대상도 없음")
        try expect(controller.state == .idle, "무음 후 idle")
    }

    await t.test("Pipeline: clipboardOnly면 lastPasteAt 미기록 (취소 대상 아님)") {
        let paste = MockPaste()
        paste.result = .clipboardOnly
        let controller = makeController(paste: paste)
        controller.startRecording()
        controller.stopAndProcess()
        await controller.processingTask?.value
        try expect(controller.lastPasteAt == nil, "자동입력 안 됐으니 lastPasteAt 미기록")
        try expect(!controller.recentDictationUndoable(), "취소 불가")
    }

    await t.test("Pipeline: runWhenIdle — idle이면 즉시, 처리 중이면 완료 후 실행") {
        let controller = makeController()
        var ran = 0
        controller.runWhenIdle { ran += 1 }
        try expectEqual(ran, 1)              // idle → 즉시 실행

        controller.startRecording()
        controller.stopAndProcess()          // state=.transcribing → isBusy
        controller.runWhenIdle { ran += 1 }  // 처리 중 → 보류
        try expectEqual(ran, 1)              // 아직 실행 안 됨
        await controller.processingTask?.value
        try expectEqual(ran, 2)              // 텍스트 붙은 뒤 자동 실행
    }

    await t.test("Pipeline: LLM 실패해도 원문 붙여넣음") {
        let paste = MockPaste()
        let history = MockHistory()
        let outcome = PostProcessOutcome(
            finalText: "안녕하세요 테스트입니다",
            llmOutput: nil,
            llmSucceeded: false,
            llmSeconds: 10
        )
        let controller = makeController(outcome: outcome, paste: paste, history: history)

        controller.startRecording()
        controller.stopAndProcess()
        await controller.processingTask?.value

        try expectEqual(paste.pasted, ["안녕하세요 테스트입니다"])
        let record = try unwrap(history.saved.first)
        try expect(record.llmSucceeded == false, "llmSucceeded false여야 함")
    }

    await t.test("Pipeline: 취소하면 아무것도 안 함") {
        let audio = MockAudio()
        let paste = MockPaste()
        let history = MockHistory()
        let controller = makeController(audio: audio, paste: paste, history: history)

        controller.startRecording()
        controller.cancel()

        try expect(audio.cancelled == true, "audio.cancelled true여야 함")
        try expect(controller.state == .idle, "취소 후 idle 상태여야 함")
        try expect(paste.pasted.isEmpty, "paste 비어있어야 함")
        try expect(history.saved.isEmpty, "history 비어있어야 함")
    }

    await t.test("Pipeline: effects 훅이 시작→종료→완료 순서로 호출") {
        let effects = MockEffects()
        let controller = makeController(effects: effects)

        controller.startRecording()
        try expectEqual(effects.events, ["start:message"])

        controller.stopAndProcess()
        await controller.processingTask?.value
        // 마이크 종료 직후 end, 처리 완료 후 complete
        try expectEqual(effects.events, ["start:message", "end", "complete"])
    }

    await t.test("Pipeline: 취소 시 effects.onRecordingEnd 호출") {
        let effects = MockEffects()
        let controller = makeController(effects: effects)
        controller.startRecording()
        controller.cancel()
        try expectEqual(effects.events, ["start:message", "end"])
    }

    await t.test("Pipeline: 시작 실패는 failed 상태") {
        let audio = MockAudio()
        audio.failOnStart = true
        let controller = makeController(audio: audio)

        controller.startRecording()

        guard case .failed = controller.state else {
            try expect(false, "failed여야 함")
            return
        }
    }

    await t.test("Pipeline: replace는 출력에만 적용되고 저장은 원문 유지") {
        let paste = MockPaste()
        let history = MockHistory()
        let controller = RecordingController(
            audio: MockAudio(),
            transcription: MockTranscriber(),
            postProcess: MockPostProcess(outcome: PostProcessOutcome(
                finalText: "다듬어진 텍스트", llmOutput: "다듬어진 텍스트",
                llmSucceeded: true, llmSeconds: 0
            )),
            paste: paste,
            history: history,
            modeProvider: { Mode.defaults[1] },
            frontmostBundleId: { nil },
            replace: { $0.replacingOccurrences(of: "다듬어진", with: "교체된") }
        )
        controller.startRecording()
        controller.stopAndProcess()
        await controller.processingTask?.value

        try expectEqual(paste.pasted, ["교체된 텍스트"])      // 출력엔 치환 적용
        let record = try unwrap(history.saved.first)
        try expectEqual(record.llmOutput, "다듬어진 텍스트")   // 저장은 원문 유지
    }

    await t.test("Pipeline: vocabulary·translate가 transcribe에 전달") {
        let transcriber = MockTranscriber()
        var mode = Mode.defaults[0]
        mode.translateToEnglish = true
        let controller = RecordingController(
            audio: MockAudio(),
            transcription: transcriber,
            postProcess: MockPostProcess(outcome: PostProcessOutcome(
                finalText: "x", llmOutput: nil, llmSucceeded: true, llmSeconds: 0
            )),
            paste: MockPaste(),
            history: MockHistory(),
            modeProvider: { mode },
            frontmostBundleId: { nil },
            vocabulary: { "Wisp, GRDB" }
        )
        controller.startRecording()
        controller.stopAndProcess()
        await controller.processingTask?.value

        try expectEqual(await transcriber.lastPrompt, "Wisp, GRDB")
        try expectEqual(await transcriber.lastTranslate, true)
    }

    await t.test("Pipeline: captureContext가 시작 시 캡처돼 후처리에 전달") {
        let postProcess = MockPostProcess(outcome: PostProcessOutcome(
            finalText: "x", llmOutput: "x", llmSucceeded: true, llmSeconds: 0
        ))
        let controller = RecordingController(
            audio: MockAudio(),
            transcription: MockTranscriber(),
            postProcess: postProcess,
            paste: MockPaste(),
            history: MockHistory(),
            modeProvider: { Mode.defaults[1] },
            frontmostBundleId: { nil },
            captureContext: { DictationContext(selectedText: "선택됨", clipboardText: "클립") }
        )
        controller.startRecording()
        controller.stopAndProcess()
        await controller.processingTask?.value

        try expectEqual(postProcess.lastContext,
                        DictationContext(selectedText: "선택됨", clipboardText: "클립"))
    }

    await t.test("Pipeline: replaceTranscription은 다음 받아쓰기부터 적용") {
        let paste = MockPaste()
        let history = MockHistory()
        let controller = RecordingController(
            audio: MockAudio(),
            transcription: MockTranscriber(output: "첫 모델"),
            postProcess: PassthroughPostProcessor(),
            paste: paste,
            history: history,
            modeProvider: { Mode.defaults[0] },
            frontmostBundleId: { nil }
        )

        controller.replaceTranscription(MockTranscriber(output: "두 번째 모델"))
        controller.startRecording()
        controller.stopAndProcess()
        await controller.processingTask?.value

        try expectEqual(paste.pasted, ["두 번째 모델"])
        try expectEqual(history.saved.first?.transcript, "두 번째 모델")
    }
}
