import Foundation

/// RecordingEffects 실제 구현 — 모드별 미디어/오디오 억제 + 사운드 피드백을 결합.
@MainActor
final class RecordingEffectsService: RecordingEffects {
    private let media: MediaController
    private let output: AudioOutputController
    private let sound: SoundFeedback
    /// 사운드 피드백 on/off만 실시간 조회 — config 전체가 아니라 필요한 Bool만 캡처.
    private let soundEnabled: () -> Bool

    init(media: MediaController,
         output: AudioOutputController,
         sound: SoundFeedback,
         soundEnabled: @escaping () -> Bool) {
        self.media = media
        self.output = output
        self.sound = sound
        self.soundEnabled = soundEnabled
    }

    func onRecordingStart(mode: Mode) {
        MultitouchHotkey.diag("EFFECTS: onRecordingStart mode=\(mode.id) media=\(mode.mediaBehavior.rawValue)")
        // 시작음을 먼저 — mute/duck 모드에선 곧 억제되어 다소 작게 들릴 수 있으나
        // 녹음 지연을 피하려 억제를 늦추지 않는다.
        if soundEnabled() { sound.playStart() }
        switch mode.mediaBehavior {
        case .none: break
        case .pause: media.pauseMedia()
        case .mute: output.suppress(to: 0)
        case .duck: output.suppress(to: 0.15)
        }
    }

    func onRecordingEnd() {
        media.resumeIfPaused()
        output.restore()
    }

    func onComplete() {
        if soundEnabled() { sound.playComplete() }
    }
}
