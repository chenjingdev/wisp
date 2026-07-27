import Foundation

/// 비공개 `MultitouchSupport` 프레임 콜백의 열화를 **관측 가능한 source 신호**로만
/// 판정하는 순수 판정기.
///
/// 배경: 앱을 오래(실측 ~19시간) 띄워두면 프레임 콜백이 stale해져 5손가락 "뗌"
/// 프레임(낮은 count)을 빠뜨린다. 그러면 `FingerCountGate`가 `.up`을 못 내
/// `RecordingController`가 `.recording`에 갇히고, 이후 제스처도 전부 무시된다
/// (HUD조차 안 뜸). 콜백 자체가 멈출 수 있으므로 **프레임에 의존하지 않는 독립
/// 타이머**가 callback 수신, source frame/timestamp 진행, per-touch frame 진행을 각각
/// 보고 이상을 판정해야 한다. 녹음 지속시간은 고장 신호가 아니므로 절대 사용하지 않는다.
///
/// `FingerCountGate`처럼 시스템 의존(타이머·실시간)을 갖지 않아 100% 결정적으로
/// 단위 테스트된다. 실제 타이머·device 재등록은 `MultitouchHotkey`가 소유한다.
struct MultitouchWatchdog {
    enum Action: Equatable {
        case none
        /// 첫 장애: 장치를 재연결하고 새 source 스트림으로 실제 hold/release를 다시 판정한다.
        case recoverDevice(StallReason)
        /// 재연결 뒤에도 신선한 프레임이 없음: 마지막 수단으로 합성 up을 낸다.
        case forceRelease(StallReason)
    }

    enum StallReason: String, Equatable {
        case callbackSilent
        case sourceFrozen
        case contactFrozen
    }

    /// 프레임 콜백/source 진척이 이만큼 완전히 멈추면 장치 장애로 본다.
    let stallTimeout: TimeInterval

    init(stallTimeout: TimeInterval = 1.5) {
        self.stallTimeout = stallTimeout
    }

    func evaluate(engaged: Bool,
                  recoveringDevice: Bool,
                  now: TimeInterval,
                  heartbeat: MultitouchHeartbeat) -> Action {
        guard engaged else { return .none }

        let reason: StallReason?
        if now - heartbeat.lastCallbackAt >= stallTimeout {
            reason = .callbackSilent
        } else if now - heartbeat.lastSourceProgressAt >= stallTimeout {
            reason = .sourceFrozen
        } else if now - heartbeat.lastContactProgressAt >= stallTimeout {
            reason = .contactFrozen
        } else {
            reason = nil
        }

        guard let reason else { return .none }
        return recoveringDevice ? .forceRelease(reason) : .recoverDevice(reason)
    }
}
