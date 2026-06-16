import Foundation

/// 녹음 중 시스템 오디오/미디어 처리 방식 (모드별 설정).
public enum MediaBehavior: String, Codable, CaseIterable, Sendable {
    /// 아무것도 하지 않음.
    case none
    /// 재생 중인 미디어를 일시정지하고, 녹음이 끝나면 재개한다 (MediaRemote).
    case pause
    /// 녹음 동안 시스템 출력을 음소거(볼륨 0)하고 끝나면 복원한다.
    case mute
    /// 녹음 동안 시스템 출력을 15%로 낮추고 끝나면 복원한다.
    case duck

    public var displayName: String {
        switch self {
        case .none: return "유지"
        case .pause: return "일시정지"
        case .mute: return "음소거"
        case .duck: return "볼륨 낮춤"
        }
    }
}
