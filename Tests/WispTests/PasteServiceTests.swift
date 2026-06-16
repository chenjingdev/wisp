import Foundation
import AppKit
@testable import WispCore

@MainActor
func pasteServiceTests(_ t: TestRunner) async {
    await t.test("Paste: 기본값은 결과를 클립보드에 남김 (복원 안 함)") {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("이전 내용", forType: .string)

        var keystrokes = 0
        let svc = PasteService(
            sendKeystroke: { keystrokes += 1 },
            isTrusted: { true },
            restoreDelay: 0.1
        )

        let result = svc.paste("새 텍스트")
        try expectEqual(result, .pasted)
        try expectEqual(keystrokes, 1)
        try expectEqual(pasteboard.string(forType: .string), "새 텍스트")

        // 복원이 일어나지 않는다 — 보이지 않는 곳에 붙었어도 ⌘V로 복구 가능
        try await Task.sleep(nanoseconds: 400_000_000)
        try expectEqual(pasteboard.string(forType: .string), "새 텍스트")
    }

    await t.test("Paste: restoreClipboard=true면 클립보드 설정·키입력·복원") {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("이전 내용", forType: .string)

        var keystrokes = 0
        let svc = PasteService(
            sendKeystroke: { keystrokes += 1 },
            isTrusted: { true },
            restoreDelay: 0.1,
            restoreClipboard: true
        )

        let result = svc.paste("새 텍스트")
        try expectEqual(result, .pasted)
        try expectEqual(keystrokes, 1)
        try expectEqual(pasteboard.string(forType: .string), "새 텍스트")

        try await Task.sleep(nanoseconds: 400_000_000)
        try expectEqual(pasteboard.string(forType: .string), "이전 내용")
    }

    await t.test("Paste: 연속 붙여넣기 시 이전 복원이 새 클립보드 안 덮음") {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("원본", forType: .string)
        let service = PasteService(
            sendKeystroke: {}, isTrusted: { true },
            restoreDelay: 0.1, restoreClipboard: true
        )
        service.paste("첫번째")
        service.paste("두번째")   // 첫번째 복원 타이머가 살아있는 동안
        try await Task.sleep(nanoseconds: 400_000_000)
        // 마지막 복원만 적용: 두번째 paste의 백업("첫번째")이 최종 클립보드
        try expectEqual(try unwrap(pasteboard.string(forType: .string)), "첫번째")
    }

    await t.test("Paste: autoPaste=false면 ⌘V 미주입·클립보드만") {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        var keystrokes = 0
        let svc = PasteService(
            sendKeystroke: { keystrokes += 1 },
            isTrusted: { true },
            restoreDelay: 0.1,
            autoPaste: false            // 자동 붙여넣기 꺼짐
        )

        let result = svc.paste("새 텍스트")
        try expectEqual(result, .clipboardOnly)
        try expectEqual(keystrokes, 0)
        try expectEqual(pasteboard.string(forType: .string), "새 텍스트")
    }

    await t.test("Paste: apply()로 autoPaste 토글 즉시 반영") {
        var keystrokes = 0
        let svc = PasteService(
            sendKeystroke: { keystrokes += 1 },
            isTrusted: { true },
            restoreDelay: 0.1,
            autoPaste: false
        )
        try expectEqual(svc.paste("a"), .clipboardOnly)
        try expectEqual(keystrokes, 0)

        svc.apply(autoPaste: true, restoreClipboard: false, pasteMethod: .clipboard)
        try expectEqual(svc.paste("b"), .pasted)
        try expectEqual(keystrokes, 1)
    }

    await t.test("Paste: keystroke 방식이면 타이핑 호출·⌘V 미주입·클립보드 폴백 기록") {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        var cmdV = 0
        var typed: [String] = []
        let svc = PasteService(
            sendKeystroke: { cmdV += 1 },
            typeText: { typed.append($0) },
            isTrusted: { true },
            restoreDelay: 0.1,
            pasteMethod: .keystroke
        )

        let result = svc.paste("타이핑됨")
        try expectEqual(result, .pasted)
        try expectEqual(cmdV, 0)              // ⌘V는 보내지 않음
        try expectEqual(typed, ["타이핑됨"])   // 문자별 타이핑
        try expectEqual(pasteboard.string(forType: .string), "타이핑됨")  // 폴백용 클립보드도 기록
    }

    await t.test("Paste: 손쉬운 사용 권한 없으면 needsAccessibility (⌘V 미주입)") {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        var keystrokes = 0
        let svc = PasteService(
            sendKeystroke: { keystrokes += 1 },
            isTrusted: { false },
            restoreDelay: 0.1
        )

        let result = svc.paste("새 텍스트")
        try expectEqual(result, .needsAccessibility)
        try expectEqual(keystrokes, 0)
        try expectEqual(pasteboard.string(forType: .string), "새 텍스트")
    }
}
