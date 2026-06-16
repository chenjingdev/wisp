import Foundation

/// 한 오디오 청크의 라이브 레벨. rms는 지속 에너지(막대 높이용, 잡음이 적어 부드럽다),
/// peak는 순간 진폭(임계 판정용 — 이 머신은 발화 peak로만 게이트를 통과한다). 둘을 함께
/// 실어 막대 표시와 "캡처 중" 판정이 같은 데이터를 쓰게 한다.
struct AudioLevel: Equatable {
    var rms: Float
    var peak: Float
    static let zero = AudioLevel(rms: 0, peak: 0)
}

enum AudioMath {
    /// 무음 게이트 문턱(정규화 샘플 [-1,1] 기준). HUD 캡처 표시와 전사 게이트가 같은 값을
    /// 공유하도록 단일 출처로 둔다. 마이크 게인에 따라 달라지므로 보수적으로 낮게 잡는다.
    static let speechPeakThreshold: Float = 0.008
    static let speechRMSThreshold: Float = 0.003

    static func rms(_ chunk: [Float]) -> Float {
        guard !chunk.isEmpty else { return 0 }
        return sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
    }

    /// 최대 절대 진폭(피크).
    static func peak(_ chunk: [Float]) -> Float {
        var p: Float = 0
        for s in chunk { let a = abs(s); if a > p { p = a } }
        return p
    }

    /// 녹음에 실제 음성이 있었는지. whisper는 무음을 "Thank you"/"감사합니다" 같은 상투구로
    /// 환각하므로, **명백한 무음**(피크·RMS 둘 다 문턱 미만)이면 전사를 건너뛰게 한다.
    /// 정규화 샘플([-1,1]) 기준. 진짜 발화는 둘 중 하나는 쉽게 넘으므로(피크 또는 지속 에너지)
    /// 오기각(실제 발화 누락) 위험을 최소화한다 — 둘 다 낮을 때만 무음으로 본다.
    static func hasSpeech(_ samples: [Float],
                          peakThreshold: Float = speechPeakThreshold,
                          rmsThreshold: Float = speechRMSThreshold) -> Bool {
        peak(samples) >= peakThreshold || rms(samples) >= rmsThreshold
    }

    /// 라이브 청크가 캡처(전사) 문턱을 넘는지 — `hasSpeech`와 동일 기준의 스칼라 버전.
    /// HUD가 "지금 들어오는 소리가 받아쓰기될 만큼 큰가"를 실시간으로 표시하는 데 쓴다.
    static func crossesSpeechThreshold(_ level: AudioLevel) -> Bool {
        level.peak >= speechPeakThreshold || level.rms >= speechRMSThreshold
    }
}
