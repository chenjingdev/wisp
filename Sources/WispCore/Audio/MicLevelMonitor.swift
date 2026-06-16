import AVFoundation

/// 설정 화면 "마이크 테스트"용 실시간 입력 레벨 모니터. 받아쓰기 파이프라인과 독립된
/// AVAudioEngine으로 입력 탭만 걸어 peak/rms를 발행한다(샘플은 모으지 않아 메모리가
/// 늘지 않는다). 사용자가 무음 감지 감도를 자기 마이크·환경에 맞춰 조절할 때 "지금 내
/// 목소리 peak가 문턱을 넘나"를 눈으로 확인하게 한다.
///
/// 진폭 스케일은 받아쓰기 게이트(`AudioMath.hasSpeech`)와 같은 [-1,1] 정규화 float이다.
/// 받아쓰기는 16kHz로 리샘플 후 측정하지만 리샘플은 진폭 스케일을 바꾸지 않으므로,
/// 무음 감도 튜닝 기준으로 입력 포맷 그대로 측정해도 충분히 일치한다.
@MainActor
final class MicLevelMonitor: ObservableObject {
    /// 현재 청크의 레벨(매 콜백 갱신).
    @Published private(set) var level: AudioLevel = .zero
    /// 최근 최고 peak — 빠르게 오르고 천천히 감쇠해 막대가 튀지 않고 "방금 낸 최고치"를 보여준다.
    @Published private(set) var peakHold: Float = 0
    @Published private(set) var isRunning = false

    private let engine = AVAudioEngine()

    func toggle() { isRunning ? stop() : start() }

    func start() {
        guard !isRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let ch = buffer.floatChannelData else { return }
            let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(buffer.frameLength)))
            let peak = AudioMath.peak(samples)
            let rms = AudioMath.rms(samples)
            Task { @MainActor in self?.ingest(peak: peak, rms: rms) }
        }
        engine.prepare()
        do { try engine.start(); isRunning = true }
        catch { input.removeTap(onBus: 0) }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        level = .zero
        peakHold = 0
    }

    private func ingest(peak: Float, rms: Float) {
        level = AudioLevel(rms: rms, peak: peak)
        // 빠르게 오르고 천천히 감쇠(콜백당 8% 감쇠 — ~수십Hz라 0.2~0.3s 잔상).
        peakHold = max(peak, peakHold * 0.92)
    }
}
