import Foundation

/// `MultitouchHotkey`의 onDown/onUp 펄스를 `TapHoldGate`에 먹이고, 게이트가 값으로
/// 요청한 타이머를 실제 `DispatchWorkItem`으로 거는 얇은 배선 레이어.
///
/// 시간 측정도 타이머 실행도 전부 여기서만 한다(게이트는 순수). 한 시점에 타이머는
/// 하나만 살아 있으므로 단일 슬롯으로 충분하다. `DispatchWorkItem.cancel()`은 이미 큐에서
/// 빠져 실행 직전인 항목은 못 막으므로, generation 토큰으로 늦게 발화한(취소·재예약된)
/// 타이머가 새 타이머 슬롯을 건드리거나 엉뚱한 phase에서 gate.fire를 호출하는 것을 막는다.
@MainActor
final class TapHoldRecognizer {
    var onHoldStart: @MainActor () -> Void = {}
    var onHoldEnd: @MainActor () -> Void = {}
    var onSingleTap: @MainActor () -> Void = {}
    var onDoubleTap: @MainActor () -> Void = {}

    private var gate: TapHoldGate
    private var timer: DispatchWorkItem?
    /// 타이머 무효화 토큰 — cancel/reschedule/reset마다 증가. 발화 시 일치할 때만 유효.
    private var timerGen = 0
    private let now: () -> TimeInterval

    init(holdThreshold: TimeInterval = 0.2,
         doubleTapWindow: TimeInterval = 0.3,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.gate = TapHoldGate(holdThreshold: holdThreshold, doubleTapWindow: doubleTapWindow)
        self.now = now
    }

    func down() { apply(gate.down(at: now())) }
    func up() { apply(gate.up(at: now())) }

    /// Esc 취소·재등록 시 — 진행 중 타이머와 게이트 상태를 초기화한다.
    func reset() {
        timer?.cancel(); timer = nil
        timerGen &+= 1
        gate.reset()
    }

    private func apply(_ outputs: [TapHoldGate.Output]) {
        for output in outputs {
            switch output {
            case .holdStart: onHoldStart()
            case .holdEnd: onHoldEnd()
            case .singleTap: onSingleTap()
            case .doubleTap: onDoubleTap()
            case .armHoldTimer(let fireAt), .armTapTimer(let fireAt):
                schedule(at: fireAt)
            case .cancelTimers:
                timer?.cancel(); timer = nil
                timerGen &+= 1
            }
        }
    }

    private func schedule(at fireAt: TimeInterval) {
        timer?.cancel()
        timerGen &+= 1
        let gen = timerGen
        let work = DispatchWorkItem { [weak self] in
            // 취소됐지만 이미 큐에서 빠진 늦은 발화는 gen 불일치로 무시 — 새 타이머 슬롯을
            // nil로 덮거나 엉뚱한 phase에서 gate.fire를 호출하지 않는다.
            guard let self, self.timerGen == gen else { return }
            self.timer = nil
            self.apply(self.gate.fire(at: self.now()))
        }
        timer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, fireAt - now()), execute: work)
    }
}
