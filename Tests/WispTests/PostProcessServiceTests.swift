import Foundation
@testable import WispCore

@MainActor
private func makeService(
    scenario: String = "ok",
    timeout: TimeInterval = 5,
    execFallback: PostProcessService.ExecFallback? = nil
) throws -> PostProcessService {
    let script = try unwrap(Bundle.module.url(
        forResource: "mock_codex_server", withExtension: "py", subdirectory: "Fixtures"
    ))
    return PostProcessService(
        makeClient: {
            CodexAppServerClient(
                executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: [script.path],
                environment: ["MOCK_SCENARIO": scenario]
            )
        },
        model: "test-model",
        timeout: timeout,
        execFallback: execFallback ?? { _ in throw WispError.codexUnavailable("exec 사용 금지") },
        restartDelayScale: 0.01
    )
}

@MainActor
func postProcessServiceTests(_ t: TestRunner) async {
    await t.test("PostProcess: 해피패스 LLM 텍스트") {
        let svc = try makeService()
        let outcome = await svc.process(transcript: "어 안녕하세요 음", mode: Mode.defaults[1])
        try expectEqual(outcome.finalText, "다듬어진 텍스트")
        try expect(outcome.llmSucceeded, "llmSucceeded가 true여야 함")
        try expectEqual(outcome.llmOutput, "다듬어진 텍스트")
    }

    await t.test("PostProcess: LLM off 모드는 codex 미사용") {
        // scenario "crash"여도 dictation 모드(llmEnabled false)는 원문 그대로
        let svc = try makeService(scenario: "crash")
        let outcome = await svc.process(transcript: "원문 텍스트", mode: Mode.defaults[0])
        try expectEqual(outcome.finalText, "원문 텍스트")
        try expect(outcome.llmSucceeded, "llmSucceeded가 true여야 함")
        try expect(outcome.llmOutput == nil, "llmOutput이 nil이어야 함")
    }

    await t.test("PostProcess: 타임아웃 시 exec 폴백") {
        let svc = try makeService(
            scenario: "timeout",
            timeout: 1,
            execFallback: { _ in "exec 폴백 결과" }
        )
        let start = Date()
        let outcome = await svc.process(transcript: "어 안녕하세요 음", mode: Mode.defaults[1])
        let elapsed = Date().timeIntervalSince(start)
        try expectEqual(outcome.finalText, "exec 폴백 결과")
        try expect(outcome.llmSucceeded, "llmSucceeded가 true여야 함")
        // C1 회귀 방지: 타임아웃이 즉시 전파돼야 함 (구버전은 mock의 sleep(30)×2 = 61s)
        try expect(elapsed < 5, "타임아웃 전파가 5초 미만이어야 함 (실측 \(elapsed)s)")
    }

    await t.test("PostProcess: 턴 중 크래시에도 행 없음") {
        let svc = try makeService(
            scenario: "crash_mid_turn",
            timeout: 5,
            execFallback: { _ in "폴백" }
        )
        let start = Date()
        let outcome = await svc.process(transcript: "어 안녕하세요 음", mode: Mode.defaults[1])
        let elapsed = Date().timeIntervalSince(start)
        try expectEqual(outcome.finalText, "폴백")
        try expect(outcome.llmSucceeded, "llmSucceeded가 true여야 함")
        // 프로세스 종료 시 awaiting이 즉시 실패해야 함 (2회 시도 + 백오프 포함 20초 미만)
        try expect(elapsed < 20, "크래시 시 즉시 실패해야 함 (실측 \(elapsed)s)")
    }

    await t.test("PostProcess: buildPrompt는 토글 켠 컨텍스트만 주입") {
        var mode = Mode.defaults[1]   // llmEnabled
        mode.useSelectedText = true
        mode.useClipboardContext = false
        let ctx = DictationContext(selectedText: "SEL_MARKER", clipboardText: "CLIP_MARKER")
        let prompt = PostProcessService.buildPrompt(mode: mode, transcript: "원문본문", context: ctx)
        try expect(prompt.contains("SEL_MARKER"), "선택 텍스트는 포함돼야")
        try expect(!prompt.contains("CLIP_MARKER"), "클립보드는 토글 꺼져 제외돼야")
        try expect(prompt.contains("원문본문"), "원문 포함")
        try expect(prompt.contains(mode.prompt), "모드 지침 포함")
    }

    await t.test("PostProcess: buildPrompt 토글 모두 꺼지면 컨텍스트 미주입") {
        var mode = Mode.defaults[1]
        mode.useSelectedText = false
        mode.useClipboardContext = false
        let ctx = DictationContext(selectedText: "SEL_MARKER", clipboardText: "CLIP_MARKER")
        let prompt = PostProcessService.buildPrompt(mode: mode, transcript: "원문", context: ctx)
        try expect(!prompt.contains("SEL_MARKER"), "선택 텍스트 제외")
        try expect(!prompt.contains("CLIP_MARKER"), "클립보드 제외")
    }

    await t.test("PostProcess: 전부 실패하면 원문 보존") {
        let svc = try makeService(
            scenario: "crash",
            execFallback: { _ in throw WispError.codexUnavailable("exec 사용 금지") }
        )
        let outcome = await svc.process(transcript: "원문 보존", mode: Mode.defaults[1])
        try expectEqual(outcome.finalText, "원문 보존")
        try expect(!outcome.llmSucceeded, "llmSucceeded가 false여야 함")
        try expect(outcome.llmOutput == nil, "llmOutput이 nil이어야 함")
    }
}
