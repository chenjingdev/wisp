import Foundation

/// 트랙패드 손가락-수 펄스(down/up)를 누름 길이·탭 횟수로 구분하는 순수 게이트.
/// 길게 누름 = hold(받아쓰기 PTT), 톡 1번 = singleTap(Enter), 톡 2번 = doubleTap(취소).
///
/// `FingerCountGate`·`HotkeyStateMachine`처럼 시스템 의존(타이머·실시간)을 갖지 않는다.
/// down/up은 외부에서, 타이머 만료는 `fire()`로 주입한다. 게이트는 "이 시각에 타이머를
/// 걸어달라"를 `armHoldTimer`/`armTapTimer` 값으로 반환하고, 실제 타이머는 배선
/// 레이어(`TapHoldRecognizer`)가 건다. 손을 완전히 떼면 멀티터치 프레임이 멈춰 시간
/// 경과를 프레임으로 감지할 수 없으므로(싱글탭 확정 등) 타이머가 필수다.
///
/// 한 이벤트가 두 효과를 낼 수 있어 반환은 `[Output]` 배열이다(예: 둘째 down은
/// 진행 중 tapTimer를 끄고 holdTimer를 거는 두 출력을 함께 낸다).
struct TapHoldGate {
    enum Output: Equatable {
        case holdStart          // hold 확정 — 받아쓰기 시작
        case holdEnd            // hold 떼짐 — 받아쓰기 종료/처리
        case singleTap          // 더블탭 윈도우 만료 — 싱글탭 확정(Enter)
        case doubleTap          // 윈도우 내 두 번째 짧은 탭(취소)
        case armHoldTimer(fireAt: TimeInterval)
        case armTapTimer(fireAt: TimeInterval)
        case cancelTimers
    }

    private enum Phase: Equatable {
        case idle
        case pressed(downAt: TimeInterval)        // 첫 누름, hold/tap 미확정
        case holding                              // hold 확정, 녹음 중
        case tapWindow(firstTapAt: TimeInterval)  // 첫 탭 후 둘째 탭 대기
        case pressed2(downAt: TimeInterval)       // 윈도우 내 둘째 누름, hold/tap 미확정
    }

    private var phase: Phase = .idle
    private let holdThreshold: TimeInterval
    private let doubleTapWindow: TimeInterval

    init(holdThreshold: TimeInterval = 0.2, doubleTapWindow: TimeInterval = 0.3) {
        self.holdThreshold = holdThreshold
        self.doubleTapWindow = doubleTapWindow
    }

    mutating func down(at now: TimeInterval) -> [Output] {
        switch phase {
        case .idle:
            phase = .pressed(downAt: now)
            return [.armHoldTimer(fireAt: now + holdThreshold)]
        case .tapWindow:
            // 둘째 누름 — tapTimer 끄고 holdTimer 건다(둘째도 길게 쥐면 hold).
            phase = .pressed2(downAt: now)
            return [.cancelTimers, .armHoldTimer(fireAt: now + holdThreshold)]
        case .pressed, .holding, .pressed2:
            return []  // 흔들림/중복 down 무시 (FingerCountGate가 대부분 막음)
        }
    }

    mutating func up(at now: TimeInterval) -> [Output] {
        switch phase {
        case .pressed(let downAt):
            if now - downAt >= holdThreshold {
                // 타이머보다 up이 먼저 온 극단 케이스 — 길었으니 hold로 보고 즉시 종료.
                phase = .idle
                return [.cancelTimers, .holdStart, .holdEnd]
            }
            // 짧은 탭 — 더블탭 윈도우 시작.
            phase = .tapWindow(firstTapAt: now)
            return [.cancelTimers, .armTapTimer(fireAt: now + doubleTapWindow)]
        case .holding:
            phase = .idle
            return [.cancelTimers, .holdEnd]
        case .pressed2(let downAt):
            if now - downAt >= holdThreshold {
                phase = .idle
                return [.cancelTimers, .holdStart, .holdEnd]
            }
            // 윈도우 내 둘째 짧은 탭 = 더블탭.
            phase = .idle
            return [.cancelTimers, .doubleTap]
        case .idle, .tapWindow:
            return []
        }
    }

    /// 타이머 만료. 어느 타이머인지는 현재 phase가 결정한다(한 시점에 하나만 산다).
    mutating func fire(at now: TimeInterval) -> [Output] {
        switch phase {
        case .pressed, .pressed2:
            // holdTimer 만료 — 여전히 눌려 있으니 hold 확정.
            phase = .holding
            return [.holdStart]
        case .tapWindow:
            // tapTimer 만료 — 둘째 탭이 없었으니 싱글탭 확정.
            phase = .idle
            return [.singleTap]
        case .idle, .holding:
            return []  // 취소된/지난 타이머의 늦은 발화 — 무시
        }
    }

    mutating func reset() {
        phase = .idle
    }
}
