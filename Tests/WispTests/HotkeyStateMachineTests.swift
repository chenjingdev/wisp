import Foundation
@testable import WispCore

@MainActor
func hotkeyStateMachineTests(_ t: TestRunner) async {
    let t0 = Date(timeIntervalSince1970: 1000)

    await t.test("Hotkey: 짧게 누르면 토글") {
        var machine = HotkeyStateMachine(threshold: 0.4)
        // 첫 번째 keyDown → 녹음 시작
        try expectEqual(machine.keyDown(at: t0), .startRecording)
        // 짧게 뗌 (0.2초) → 토글 확정, 아무 액션 없음
        try expectEqual(machine.keyUp(at: t0.addingTimeInterval(0.2)), .none)
        // 두 번째 누름 (3초 후) → 종료 후보 (개입 가능성 때문에 keyUp에서 확정)
        try expectEqual(machine.keyDown(at: t0.addingTimeInterval(3)), .none)
        // 뗌 → 녹음 종료 확정
        try expectEqual(machine.keyUp(at: t0.addingTimeInterval(3.1)), .stopRecording)
    }

    await t.test("Hotkey: 길게 누르면 PTT") {
        var machine = HotkeyStateMachine(threshold: 0.4)
        // keyDown → 녹음 시작
        try expectEqual(machine.keyDown(at: t0), .startRecording)
        // 길게 뗌 (1.5초) → PTT 종료
        try expectEqual(machine.keyUp(at: t0.addingTimeInterval(1.5)), .stopRecording)
    }

    await t.test("Hotkey: 외부 취소 후 리셋") {
        var machine = HotkeyStateMachine(threshold: 0.4)
        // keyDown
        let _ = machine.keyDown(at: t0)
        // 외부에서 취소
        machine.reset()
        // keyUp → 이미 리셋됐으므로 아무 액션 없음
        try expectEqual(machine.keyUp(at: t0.addingTimeInterval(0.2)), .none)
        // 새 keyDown → 녹음 시작
        try expectEqual(machine.keyDown(at: t0.addingTimeInterval(1)), .startRecording)
    }

    await t.test("Hotkey: 개입 시 녹음 취소 (단독 보조키 ⌃C 시나리오)") {
        var machine = HotkeyStateMachine(threshold: 0.4)
        // ⌃ down → 녹음 시작
        try expectEqual(machine.keyDown(at: t0), .startRecording)
        // C 키 개입 → 단축키 아님, 녹음 취소
        try expectEqual(machine.interrupt(), .cancelRecording)
        // 같은 누름 중 추가 개입(키 반복) → 무시
        try expectEqual(machine.interrupt(), .none)
        // ⌃ up → 아무 액션 없음
        try expectEqual(machine.keyUp(at: t0.addingTimeInterval(0.1)), .none)
        // 다음 깨끗한 누름 → 정상 시작
        try expectEqual(machine.keyDown(at: t0.addingTimeInterval(1)), .startRecording)
    }

    await t.test("Hotkey: 토글 녹음 중 개입은 녹음 유지") {
        var machine = HotkeyStateMachine(threshold: 0.4)
        // 토글 시작
        try expectEqual(machine.keyDown(at: t0), .startRecording)
        try expectEqual(machine.keyUp(at: t0.addingTimeInterval(0.2)), .none)
        // 녹음 중 ⌃C 입력: ⌃ down은 종료 후보지만 개입으로 무효 — 녹음은 계속
        try expectEqual(machine.keyDown(at: t0.addingTimeInterval(2)), .none)
        try expectEqual(machine.interrupt(), .none)
        try expectEqual(machine.keyUp(at: t0.addingTimeInterval(2.2)), .none)
        // 이후 깨끗한 탭 → 정상 종료
        try expectEqual(machine.keyDown(at: t0.addingTimeInterval(4)), .none)
        try expectEqual(machine.keyUp(at: t0.addingTimeInterval(4.1)), .stopRecording)
    }
}
