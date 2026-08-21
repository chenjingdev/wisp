import AppKit
@testable import WispCore

@MainActor
func hotkeyCaptureTests(_ t: TestRunner) async {
    await t.test("Capture: 보조키+일반키 → 콤보") {
        var c = HotkeyCapture()
        // ⌥ 누름 (미확정) → Space keyDown → 콤보 확정
        try expectEqual(c.handleFlagsChanged(flags: [.option]), .pending)
        try expectEqual(
            c.handleKeyDown(keyCode: 49, flags: [.option]),
            .combo(keyCode: 49, carbonModifiers: 2048)
        )
    }

    await t.test("Capture: 보조키만 눌렀다 떼면 단독키") {
        var c = HotkeyCapture()
        try expectEqual(c.handleFlagsChanged(flags: [.control]), .pending)
        try expectEqual(c.handleFlagsChanged(flags: []), .bareModifier("control"))
    }

    await t.test("Capture: Fn만 눌렀다 떼면 단독키") {
        var c = HotkeyCapture()
        try expectEqual(c.handleFlagsChanged(flags: [.function]), .pending)
        try expectEqual(c.handleFlagsChanged(flags: []), .bareModifier("function"))
    }

    await t.test("Capture: Fn+일반키를 단독 Fn으로 오인하지 않음") {
        var c = HotkeyCapture()
        try expectEqual(c.handleFlagsChanged(flags: [.function]), .pending)
        try expectEqual(c.handleKeyDown(keyCode: 49, flags: [.function]), .ignored)
        try expectEqual(c.handleFlagsChanged(flags: []), .pending)
    }

    await t.test("ModifierHotkey: function 이름을 Fn 플래그로 변환") {
        try expectEqual(ModifierHotkey.flag(named: "function"), .function)
    }

    await t.test("Capture: 보조키 둘 이상은 단독키로 확정 안 됨") {
        var c = HotkeyCapture()
        _ = c.handleFlagsChanged(flags: [.control])
        _ = c.handleFlagsChanged(flags: [.control, .command])
        try expectEqual(c.handleFlagsChanged(flags: []), .pending)
    }

    await t.test("Capture: Esc는 취소, 보조키 없는 일반키는 무시") {
        var c = HotkeyCapture()
        try expectEqual(c.handleKeyDown(keyCode: 53, flags: []), .cancelled)
        var c2 = HotkeyCapture()
        try expectEqual(c2.handleKeyDown(keyCode: 0, flags: []), .ignored)
    }

    await t.test("Capture: 라벨 생성") {
        try expectEqual(HotkeyCapture.label(keyCode: 49, carbonModifiers: 2048), "⌥Space")
        try expectEqual(HotkeyCapture.label(keyCode: 9, carbonModifiers: 0x100 | 0x200), "⇧⌘V")
        try expectEqual(HotkeyCapture.label(keyCode: 999, carbonModifiers: 0x1000), "⌃키999")
    }
}
