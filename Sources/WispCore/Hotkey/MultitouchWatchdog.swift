import Foundation

/// 비공개 `MultitouchSupport` 프레임 콜백의 장시간 열화를 감지하는 순수 판정기.
///
/// 배경: 앱을 오래(실측 ~19시간) 띄워두면 프레임 콜백이 stale해져 5손가락 "뗌"
/// 프레임(낮은 count)을 빠뜨린다. 그러면 `FingerCountGate`가 `.up`을 못 내
/// `RecordingController`가 `.recording`에 갇히고, 이후 제스처도 전부 무시된다
/// (HUD조차 안 뜸). 콜백 자체가 멈출 수 있으므로 **프레임에 의존하지 않는 독립
/// 타이머**가 마지막 프레임 수신 시각을 보고 이상을 판정해야 한다.
///
/// `FingerCountGate`처럼 시스템 의존(타이머·실시간)을 갖지 않아 100% 결정적으로
/// 단위 테스트된다. 실제 타이머·device 재등록은 `MultitouchHotkey`가 소유한다.
struct MultitouchWatchdog {
    enum Action: Equatable {
        case none
        /// 녹음 중인데 프레임이 끊김 — 합성 `up`으로 갇힌 녹음을 풀고 device를 재등록한다.
        case recoverStuck
        /// 유휴(접촉 없음)가 오래 지속됨 — 콜백이 조용히 죽었을 수 있어 주기적으로 재등록한다.
        case reregisterIdle
    }

    /// 녹음 중 프레임이 이만큼 끊기면 stall로 본다. 손가락이 닿아 있는 한 멀티터치
    /// 프레임은 계속 흐르므로(정지해 있어도 보고됨), 정상 PTT에서 이 시간만큼 완전히
    /// 멈추는 일은 드물다. 보수적으로 잡아 정상 녹음의 조기 종료를 피한다.
    let stallTimeout: TimeInterval
    /// 접촉이 전혀 없을 때 device를 주기적으로 재등록하는 간격(콜백 stale 예방).
    let idleReregisterInterval: TimeInterval

    init(stallTimeout: TimeInterval = 1.5, idleReregisterInterval: TimeInterval = 1800) {
        self.stallTimeout = stallTimeout
        self.idleReregisterInterval = idleReregisterInterval
    }

    /// - Parameters:
    ///   - engaged: `FingerCountGate`가 `.down`을 냈고 아직 `.up`을 안 낸 상태(=녹음 중으로 간주).
    ///   - currentCount: 마지막 프레임의 접촉 수(유휴 재등록이 진행 중 제스처를 끊지 않게 가드).
    ///   - now: 단조 증가 타임스탬프(초).
    ///   - lastFrameAt: 마지막 프레임을 받은 시각.
    ///   - lastDeviceStartAt: 마지막으로 device를 (재)등록한 시각.
    func evaluate(engaged: Bool, currentCount: Int, now: TimeInterval,
                  lastFrameAt: TimeInterval, lastDeviceStartAt: TimeInterval) -> Action {
        if engaged {
            // 녹음 중 프레임이 끊겼으면 "뗌"을 영영 못 받는다 — 합성 up으로 복구.
            if now - lastFrameAt >= stallTimeout { return .recoverStuck }
            return .none
        }
        // 유휴: 접촉이 없을 때만(진행 중 제스처를 끊지 않게) 오래된 등록을 갱신한다.
        if currentCount == 0, now - lastDeviceStartAt >= idleReregisterInterval {
            return .reregisterIdle
        }
        return .none
    }
}
