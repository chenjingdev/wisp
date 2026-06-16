import Foundation

/// 핫키 누름/뗌/개입 이벤트를 녹음 시작/종료/취소 액션으로 변환하는 순수 상태 기계.
/// threshold 미만으로 짧게 누르면 토글, 그 이상 유지하면 push-to-talk.
/// 단독 보조키(⌃ 등) 모드에서는 유지 중 다른 키가 개입하면(예: ⌃C 입력)
/// interrupt()로 이번 누름을 단축키가 아닌 것으로 판정한다.
struct HotkeyStateMachine {
    enum Action: Equatable {
        case startRecording
        case stopRecording
        case cancelRecording
        case none
    }

    private enum Phase {
        case idle
        case pressed(since: Date)   // 녹음은 이미 시작됨, 토글/PTT 미확정
        case recordingLocked        // 토글 확정 — 다음 깨끗한 탭에 종료
        case stopPending            // 종료 후보 탭 진행 중 (keyUp에서 확정)
        case suppressed             // 개입으로 녹음 취소됨 — keyUp까지 무시
        case suppressedLocked       // 녹음 유지 중 개입 — keyUp 후 locked 복귀
    }

    private var phase: Phase = .idle
    private let threshold: TimeInterval

    init(threshold: TimeInterval) {
        self.threshold = threshold
    }

    mutating func keyDown(at now: Date) -> Action {
        switch phase {
        case .idle:
            phase = .pressed(since: now)
            return .startRecording
        case .recordingLocked:
            // 종료는 keyUp에서 확정 — 개입(⌃C 등)이면 녹음을 계속한다
            phase = .stopPending
            return .none
        case .pressed, .stopPending, .suppressed, .suppressedLocked:
            return .none  // 키 반복 이벤트 무시
        }
    }

    mutating func keyUp(at now: Date) -> Action {
        switch phase {
        case .pressed(let since):
            if now.timeIntervalSince(since) < threshold {
                phase = .recordingLocked
                return .none
            }
            phase = .idle
            return .stopRecording
        case .stopPending:
            phase = .idle
            return .stopRecording
        case .suppressed:
            phase = .idle
            return .none
        case .suppressedLocked:
            phase = .recordingLocked
            return .none
        case .idle, .recordingLocked:
            return .none
        }
    }

    /// 핫키 유지 중 다른 키/보조키 개입 — 이번 누름은 단축키 입력이 아니다.
    mutating func interrupt() -> Action {
        switch phase {
        case .pressed:
            phase = .suppressed
            return .cancelRecording
        case .stopPending:
            phase = .suppressedLocked
            return .none
        case .idle, .recordingLocked, .suppressed, .suppressedLocked:
            return .none
        }
    }

    mutating func reset() {
        phase = .idle
    }
}
