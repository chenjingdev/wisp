import Foundation

/// 트랙패드 손가락 접촉 수의 흐름을 누름/뗌 이벤트로 바꾸는 순수 게이트(히스테리시스).
///
/// 실측 결과 N손가락을 동시에 정확히 안착시키기는 어렵다 — 5를 올리려 해도 접촉 수가
/// `4→5→3→5`처럼 심하게 흔들리고 5가 유지되는 시간이 0.05~0.15초로 들쭉날쭉하다.
/// 단순히 "count >= target 연속 유지"를 요구하면 이 흔들림 때문에 트리거가 거의 안 된다.
///
/// 그래서 두 임계로 나눈다:
///  - **engage(=target)**: 타이머는 목표 수에 *한번 닿아야* 시작한다. 평소 3손가락 스크롤은
///    5에 안 닿으므로 절대 엔게이지되지 않는다(우발 방지).
///  - **release(=target-2)**: 한번 엔게이지하면, 그 아래로 떨어지기 전까지 흔들림(4,3)을
///    유지로 본다. release 미만으로 떨어져야 타이머 취소(엔게이지 중) 또는 .up(눌림 중).
///
/// 시스템 의존이 없어 단위 테스트가 가능하다(실제 멀티터치 콜백은 이 게이트에
/// 매 프레임 count와 단조 증가 타임스탬프를 먹인다).
struct FingerCountGate {
    enum Event: Equatable { case down, up, none }

    let target: Int
    let release: Int          // 이 미만으로 떨어져야 해제 — 안착 흔들림 흡수
    let debounce: TimeInterval
    private var engagedSince: TimeInterval?
    private var isDown = false
    /// system sleep처럼 release frame을 관측할 수 없는 명시적 lifecycle reset 뒤,
    /// 아직 얹혀 있는 손가락을 새 down으로 오인하지 않게 실제 neutral까지 재무장을 막는다.
    private var blockedUntilNeutral = false

    init(target: Int, debounce: TimeInterval = 0.12) {
        self.target = max(1, target)
        self.release = max(1, self.target - 2)
        self.debounce = debounce
    }

    /// 매 프레임 호출한다. now는 단조 증가 타임스탬프(초).
    mutating func update(count: Int, now: TimeInterval) -> Event {
        if blockedUntilNeutral {
            if count == 0 { blockedUntilNeutral = false }
            return .none
        }
        if isDown {
            // 눌림 유지: release 미만으로 떨어지면 뗌.
            if count < release { isDown = false; engagedSince = nil; return .up }
            return .none
        }
        if let since = engagedSince {
            // 엔게이지 중: release 이상 유지되어야 디바운스를 채운다.
            if count < release { engagedSince = nil; return .none }   // 흔들림이 release 밑 → 취소
            if now - since >= debounce { isDown = true; engagedSince = nil; return .down }
            return .none
        }
        // 미엔게이지: 목표 수에 닿으면 down. debounce>0이면 release 이상으로 그만큼 유지돼야
        // 하고(흔들림 억제), debounce==0이면 한 프레임 피크도 즉시 인식한다 — 빠른 톡이 다음
        // 프레임에 떨어져 .down 없이 취소되는 것을 막는다(트랙패드 탭은 debounce 0을 쓴다).
        if count >= target {
            if debounce <= 0 { isDown = true; return .down }
            engagedSince = now
        }
        return .none
    }

    /// 강제 초기화(취소·재등록 시). `requireRelease`면 실제 0-contact 프레임을 한 번
    /// 확인한 뒤에만 다음 제스처를 받는다.
    mutating func reset(requireRelease: Bool = false) {
        engagedSince = nil
        isDown = false
        blockedUntilNeutral = requireRelease
    }
}
