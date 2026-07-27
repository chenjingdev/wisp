import Foundation
@testable import WispCore

@MainActor
func multitouchWatchdogTests(_ t: TestRunner) async {
    await t.test("MultitouchWatchdog: 녹음 중 프레임이 stallTimeout 넘게 끊기면 recoverStuck") {
        let w = MultitouchWatchdog(stallTimeout: 1.5, idleReregisterInterval: 1800)
        // 녹음 중(engaged), 마지막 프레임 10.0, 현재 11.6 → 1.6s ≥ 1.5 → 복구
        try expectEqual(
            w.evaluate(engaged: true, currentCount: 5, now: 11.6,
                       lastFrameAt: 10.0, lastDeviceStartAt: 0.0),
            .recoverStuck
        )
    }

    await t.test("MultitouchWatchdog: 녹음 중이라도 프레임이 계속 오면 none(정상 PTT)") {
        let w = MultitouchWatchdog(stallTimeout: 1.5, idleReregisterInterval: 1800)
        // 1.6s 동안 눌렀지만 마지막 프레임이 0.2s 전 → 아직 stall 아님
        try expectEqual(
            w.evaluate(engaged: true, currentCount: 5, now: 11.6,
                       lastFrameAt: 11.4, lastDeviceStartAt: 0.0,
                       engagedAt: 10.0),
            .none
        )
    }

    await t.test("MultitouchWatchdog: 프레임은 살아도 접촉 수가 오래 0으로 안 돌아오면 recoverStuck") {
        let w = MultitouchWatchdog(stallTimeout: 1.5,
                                   idleReregisterInterval: 1800,
                                   stuckTouchTimeout: 45)
        try expectEqual(
            w.evaluate(engaged: true, currentCount: 5, now: 145,
                       lastFrameAt: 144.9, lastDeviceStartAt: 0.0,
                       engagedAt: 100),
            .recoverStuck
        )
    }

    await t.test("MultitouchWatchdog: 최대 hold 직전에는 정상 긴 PTT로 보고 none") {
        let w = MultitouchWatchdog(stallTimeout: 1.5,
                                   idleReregisterInterval: 1800,
                                   stuckTouchTimeout: 45)
        try expectEqual(
            w.evaluate(engaged: true, currentCount: 5, now: 144.9,
                       lastFrameAt: 144.8, lastDeviceStartAt: 0.0,
                       engagedAt: 100),
            .none
        )
    }

    await t.test("MultitouchWatchdog: stall 경계 — 정확히 timeout이면 복구, 직전이면 none") {
        let w = MultitouchWatchdog(stallTimeout: 1.5, idleReregisterInterval: 1800)
        try expectEqual(
            w.evaluate(engaged: true, currentCount: 5, now: 1.5,
                       lastFrameAt: 0.0, lastDeviceStartAt: 0.0),
            .recoverStuck
        )
        try expectEqual(
            w.evaluate(engaged: true, currentCount: 5, now: 1.49,
                       lastFrameAt: 0.0, lastDeviceStartAt: 0.0),
            .none
        )
    }

    await t.test("MultitouchWatchdog: 유휴 + 접촉 0 + 간격 경과면 reregisterIdle") {
        let w = MultitouchWatchdog(stallTimeout: 1.5, idleReregisterInterval: 1800)
        try expectEqual(
            w.evaluate(engaged: false, currentCount: 0, now: 1801,
                       lastFrameAt: 0.0, lastDeviceStartAt: 0.0),
            .reregisterIdle
        )
    }

    await t.test("MultitouchWatchdog: 유휴여도 접촉이 남아 있으면 재등록 보류(제스처 끊김 방지)") {
        let w = MultitouchWatchdog(stallTimeout: 1.5, idleReregisterInterval: 1800)
        // 간격은 지났지만 손가락이 닿아 있음(count>0) → 재등록하지 않는다
        try expectEqual(
            w.evaluate(engaged: false, currentCount: 2, now: 5000,
                       lastFrameAt: 4999, lastDeviceStartAt: 0.0),
            .none
        )
    }

    await t.test("MultitouchWatchdog: 유휴지만 간격 미경과면 none") {
        let w = MultitouchWatchdog(stallTimeout: 1.5, idleReregisterInterval: 1800)
        try expectEqual(
            w.evaluate(engaged: false, currentCount: 0, now: 1799,
                       lastFrameAt: 0.0, lastDeviceStartAt: 0.0),
            .none
        )
    }

    await t.test("MultitouchWatchdog: 녹음 중 판정이 유휴 재등록보다 우선") {
        let w = MultitouchWatchdog(stallTimeout: 1.5, idleReregisterInterval: 1800)
        // engaged면 idle 간격이 아무리 지나도 recover/none만 나오고 reregisterIdle은 안 난다
        try expectEqual(
            w.evaluate(engaged: true, currentCount: 5, now: 100000,
                       lastFrameAt: 99999.9, lastDeviceStartAt: 0.0),
            .none
        )
    }
}
