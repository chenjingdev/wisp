import AppKit

/// 녹음 시작/완료를 알리는 짧은 시스템 사운드.
@MainActor
final class SoundFeedback {
    private static let startSound = "Tink"     // 녹음 시작 — 가볍고 짧은 큐
    private static let completeSound = "Glass"  // 처리 완료 — 또렷한 완료음

    func playStart() { NSSound(named: Self.startSound)?.play() }
    func playComplete() { NSSound(named: Self.completeSound)?.play() }
}
