import Foundation
@testable import WispCore

@MainActor func codexLocatorTests(_ t: TestRunner) async {
    let common = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]

    await t.test("CodexLocator: 설정 경로가 유효하면 그대로(사용자 지정 우선)") {
        let result = CodexLocator.resolve(
            configured: "/custom/codex",
            common: common,
            fileExists: { $0 == "/custom/codex" },
            shellWhich: { "/usr/local/bin/codex" }   // 유효한 설정이 있으면 셸은 안 봄
        )
        try expectEqual(result, "/custom/codex")
    }

    await t.test("CodexLocator: 설정 경로가 없으면 셸 PATH로 탐지") {
        let result = CodexLocator.resolve(
            configured: "/opt/homebrew/bin/codex",     // 이 머신엔 없음
            common: common,
            fileExists: { $0 == "/Users/me/.bun/bin/codex" },
            shellWhich: { "/Users/me/.bun/bin/codex" }
        )
        try expectEqual(result, "/Users/me/.bun/bin/codex")
    }

    await t.test("CodexLocator: 설정·셸 모두 실패하면 흔한 위치로 폴백") {
        let result = CodexLocator.resolve(
            configured: "/opt/homebrew/bin/codex",
            common: common,
            fileExists: { $0 == "/usr/local/bin/codex" },
            shellWhich: { nil }
        )
        try expectEqual(result, "/usr/local/bin/codex")
    }

    await t.test("CodexLocator: 셸이 절대경로 아닌 값을 줘도(별칭 등) fileExists로 걸러짐") {
        // 셸이 경로를 줬지만 실제로 없으면 채택 안 함 → 흔한 위치로 넘어감
        let result = CodexLocator.resolve(
            configured: "",
            common: common,
            fileExists: { $0 == "/opt/homebrew/bin/codex" },
            shellWhich: { "/stale/codex" }
        )
        try expectEqual(result, "/opt/homebrew/bin/codex")
    }

    await t.test("CodexLocator: 아무 데도 없으면 nil(→ Passthrough 강등)") {
        let result = CodexLocator.resolve(
            configured: "/opt/homebrew/bin/codex",
            common: common,
            fileExists: { _ in false },
            shellWhich: { nil }
        )
        try expect(result == nil, "어디에도 없으면 nil")
    }
}
