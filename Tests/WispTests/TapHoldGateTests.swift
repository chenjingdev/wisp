import Foundation
@testable import WispCore

@MainActor
func tapHoldGateTests(_ t: TestRunner) async {
    // fireAt 등호 비교의 부동소수 오차를 피하려 정수 파라미터(hold=2, window=3)를 쓴다.
    typealias O = TapHoldGate.Output

    await t.test("TapHoldGate: 길게 누름 → holdStart, 떼면 holdEnd") {
        var g = TapHoldGate(holdThreshold: 2, doubleTapWindow: 3)
        try expectEqual(g.down(at: 0), [O.armHoldTimer(fireAt: 2)])
        try expectEqual(g.fire(at: 2), [O.holdStart])          // 여전히 눌림 → hold 확정
        try expectEqual(g.up(at: 5), [O.cancelTimers, O.holdEnd])
    }

    await t.test("TapHoldGate: 짧은 탭 → 윈도우 만료로 singleTap") {
        var g = TapHoldGate(holdThreshold: 2, doubleTapWindow: 3)
        try expectEqual(g.down(at: 0), [O.armHoldTimer(fireAt: 2)])
        try expectEqual(g.up(at: 1), [O.cancelTimers, O.armTapTimer(fireAt: 4)])  // 1<2 = 탭
        try expectEqual(g.fire(at: 4), [O.singleTap])
    }

    await t.test("TapHoldGate: 윈도우 내 두 번째 짧은 탭 → doubleTap") {
        var g = TapHoldGate(holdThreshold: 2, doubleTapWindow: 3)
        try expectEqual(g.down(at: 0), [O.armHoldTimer(fireAt: 2)])
        try expectEqual(g.up(at: 1), [O.cancelTimers, O.armTapTimer(fireAt: 4)])
        try expectEqual(g.down(at: 2), [O.cancelTimers, O.armHoldTimer(fireAt: 4)])
        try expectEqual(g.up(at: 3), [O.cancelTimers, O.doubleTap])               // 3-2=1<2
    }

    await t.test("TapHoldGate: 탭 후 길게 쥐면 hold (더블탭 아님)") {
        var g = TapHoldGate(holdThreshold: 2, doubleTapWindow: 3)
        _ = g.down(at: 0)
        try expectEqual(g.up(at: 1), [O.cancelTimers, O.armTapTimer(fireAt: 4)])
        try expectEqual(g.down(at: 2), [O.cancelTimers, O.armHoldTimer(fireAt: 4)])
        try expectEqual(g.fire(at: 4), [O.holdStart])          // 둘째를 길게 → hold
        try expectEqual(g.up(at: 6), [O.cancelTimers, O.holdEnd])
    }

    await t.test("TapHoldGate: 타이머보다 up이 먼저 온 긴 누름도 hold 처리") {
        var g = TapHoldGate(holdThreshold: 2, doubleTapWindow: 3)
        _ = g.down(at: 0)
        try expectEqual(g.up(at: 2), [O.cancelTimers, O.holdStart, O.holdEnd])  // 2>=2
    }

    await t.test("TapHoldGate: 흔들림·중복 down 무시") {
        var g = TapHoldGate(holdThreshold: 2, doubleTapWindow: 3)
        try expectEqual(g.down(at: 0), [O.armHoldTimer(fireAt: 2)])
        try expectEqual(g.down(at: 1), [])                     // pressed 중 중복 down 무시
        try expectEqual(g.fire(at: 2), [O.holdStart])
    }

    await t.test("TapHoldGate: 늦은/취소된 타이머 발화 무시") {
        var g = TapHoldGate(holdThreshold: 2, doubleTapWindow: 3)
        _ = g.down(at: 0)
        try expectEqual(g.fire(at: 2), [O.holdStart])          // holding
        try expectEqual(g.fire(at: 3), [])                     // holding 중 늦은 fire 무시
    }

    await t.test("TapHoldGate: reset 후 깨끗한 새 시작") {
        var g = TapHoldGate(holdThreshold: 2, doubleTapWindow: 3)
        _ = g.down(at: 0)
        g.reset()
        try expectEqual(g.up(at: 1), [])                       // reset 후 idle → 아무것도
        try expectEqual(g.down(at: 2), [O.armHoldTimer(fireAt: 4)])
    }
}
