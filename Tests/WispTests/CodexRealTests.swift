import Foundation
@testable import WispCore

/// 실제 codex app-server를 호출하는 옵트인 테스트.
/// 실행: WISP_REAL_CODEX=1 ./scripts/test.sh CodexReal
@MainActor
func codexRealTests(_ t: TestRunner) async {
    await t.test("CodexReal: 실제 spark 후처리 왕복") {
        guard ProcessInfo.processInfo.environment["WISP_REAL_CODEX"] == "1" else {
            try skip("옵트인 테스트 — WISP_REAL_CODEX=1로 실행")
            return
        }
        let codexPath = "/opt/homebrew/bin/codex"
        guard FileManager.default.isExecutableFile(atPath: codexPath) else {
            try skip("codex 미설치")
            return
        }
        let service = PostProcessService(
            makeClient: {
                CodexAppServerClient(
                    executableURL: URL(fileURLWithPath: codexPath),
                    arguments: ["app-server", "-c", "mcp_servers={}", "-c", "notify=[]"]
                )
            },
            model: "gpt-5.3-codex-spark",
            timeout: 30,
            execFallback: { _ in throw WispError.codexUnavailable("app-server 경로 검증 목적") }
        )
        let outcome = await service.process(
            transcript: "어 그 내일 음 3시에 회의실에서 보자고 어 전해줘",
            mode: Mode.defaults[1]   // 메시지 모드
        )
        print("     출력: \(outcome.finalText) (LLM \(String(format: "%.2f", outcome.llmSeconds))초)")
        try expect(outcome.llmSucceeded, "LLM 실패: \(outcome.finalText)")
        try expect(outcome.llmOutput != nil)
        try expect(!outcome.finalText.contains("어 그"), "군말 제거 안 됨: \(outcome.finalText)")
    }
}
