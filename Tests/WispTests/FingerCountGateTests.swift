import Foundation
@testable import WispCore

@MainActor
func fingerCountGateTests(_ t: TestRunner) async {
    await t.test("FingerCountGate: 목표 유지 디바운스 후 down, 떼면 up") {
        var g = FingerCountGate(target: 5, debounce: 0.15)
        try expectEqual(g.update(count: 5, now: 0.0), .none)   // 접촉 시작
        try expectEqual(g.update(count: 5, now: 0.1), .none)   // 0.1 < 0.15
        try expectEqual(g.update(count: 5, now: 0.2), .down)   // 디바운스 통과
        try expectEqual(g.update(count: 5, now: 0.3), .none)   // 이미 down
        try expectEqual(g.update(count: 0, now: 0.4), .up)     // 떼면 up
        try expectEqual(g.update(count: 0, now: 0.5), .none)
    }

    await t.test("FingerCountGate: 디바운스 전에 떼면 우발로 무시 (down 없음)") {
        var g = FingerCountGate(target: 5, debounce: 0.15)
        try expectEqual(g.update(count: 5, now: 0.0), .none)
        try expectEqual(g.update(count: 2, now: 0.05), .none)  // 0.05s 만에 떨어짐 → 우발
        // 다시 올리면 타이머가 처음부터 — 0.05 기준이 아니라 0.06부터
        try expectEqual(g.update(count: 5, now: 0.06), .none)
        try expectEqual(g.update(count: 5, now: 0.15), .none)  // 0.06~0.15 = 0.09 < 0.15
        try expectEqual(g.update(count: 5, now: 0.21), .down)  // 0.06+0.15
    }

    await t.test("FingerCountGate: count가 목표 이상이면 초과도 인정 (6손가락)") {
        var g = FingerCountGate(target: 5, debounce: 0.1)
        try expectEqual(g.update(count: 6, now: 0.0), .none)
        try expectEqual(g.update(count: 6, now: 0.1), .down)
    }

    await t.test("FingerCountGate: 5 도달 후 4·3으로 흔들려도 유지(히스테리시스)") {
        var g = FingerCountGate(target: 5, debounce: 0.15)   // release=3
        try expectEqual(g.update(count: 5, now: 0.0), .none)   // 5 도달 → 엔게이지
        try expectEqual(g.update(count: 4, now: 0.05), .none)  // 4>=release(3) → 유지
        try expectEqual(g.update(count: 3, now: 0.10), .none)  // 3>=release → 유지
        try expectEqual(g.update(count: 5, now: 0.16), .down)  // 흔들림 내내 유지, 0.16>=0.15 → down
        try expectEqual(g.update(count: 4, now: 0.20), .none)  // 눌림 중 4>=release → 유지
        try expectEqual(g.update(count: 2, now: 0.25), .up)    // 2<release → 뗌
    }

    await t.test("FingerCountGate: 목표에 한번도 안 닿으면 엔게이지 안 함(우발 방지)") {
        var g = FingerCountGate(target: 5, debounce: 0.1)      // release=3
        try expectEqual(g.update(count: 3, now: 0.0), .none)   // 3은 target 미도달
        try expectEqual(g.update(count: 4, now: 0.2), .none)   // 4도 target 미도달 → 엔게이지 없음
        try expectEqual(g.update(count: 4, now: 0.5), .none)   // 시간 지나도 트리거 안 됨
    }

    await t.test("FingerCountGate: debounce 0이면 한 프레임 피크도 즉시 down (트랙패드 톡)") {
        var g = FingerCountGate(target: 5, debounce: 0)        // release=3
        try expectEqual(g.update(count: 5, now: 0.0), .down)   // 도달 즉시 down — 다음 프레임 안 기다림
        try expectEqual(g.update(count: 2, now: 0.01), .up)    // 바로 떨어져도 down→up 쌍이 보존됨(톡)
        // 이전 버그: 첫 프레임에 engagedSince만 잡고 .none → 다음 프레임에 떨어지면 .down 없이 씹힘
        try expectEqual(g.update(count: 5, now: 0.02), .down)  // 다시 톡 → 또 즉시 down
    }

    await t.test("FingerCountGate: reset은 상태를 초기화") {
        var g = FingerCountGate(target: 3, debounce: 0.1)
        _ = g.update(count: 3, now: 0.0)
        try expectEqual(g.update(count: 3, now: 0.2), .down)
        g.reset()
        try expectEqual(g.update(count: 0, now: 0.3), .none)   // reset 후라 up 안 나옴
    }

    await t.test("FingerCountGate: 강제 복구 뒤 neutral 전에는 재녹음하지 않음") {
        var g = FingerCountGate(target: 5, debounce: 0)
        try expectEqual(g.update(count: 5, now: 0.0), .down)

        g.reset(requireRelease: true)
        // device를 재등록해 5손가락이 계속 보여도 새 down으로 bounce하지 않는다.
        try expectEqual(g.update(count: 5, now: 1.0), .none)
        try expectEqual(g.update(count: 5, now: 10.0), .none)
        // 실제 0-contact를 확인한 프레임은 재무장만 하고 이벤트를 내지 않는다.
        try expectEqual(g.update(count: 0, now: 10.1), .none)
        // 완전히 뗀 뒤 다음 제스처부터 정상 동작한다.
        try expectEqual(g.update(count: 5, now: 10.2), .down)
    }
}
