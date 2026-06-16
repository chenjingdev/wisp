import Foundation
@testable import WispCore

@MainActor func audioTests(_ t: TestRunner) async {
    await t.test("Audio: 무음 RMS는 0") {
        let result = AudioMath.rms([0, 0, 0, 0])
        try expectEqual(result, 0.0, accuracy: 0.0001)
    }

    await t.test("Audio: 일정 신호 RMS") {
        let result = AudioMath.rms([0.5, -0.5, 0.5, -0.5])
        try expectEqual(result, 0.5, accuracy: 0.0001)
    }

    await t.test("Audio: peak는 최대 절대 진폭") {
        try expectEqual(AudioMath.peak([0.01, -0.2, 0.05]), 0.2, accuracy: 0.0001)
        try expectEqual(AudioMath.peak([]), 0.0, accuracy: 0.0001)
    }

    await t.test("Audio: hasSpeech — 무음/노이즈 플로어는 false, 발화는 true") {
        // 명백한 무음(피크·RMS 둘 다 낮음) → 전사 건너뜀
        try expect(!AudioMath.hasSpeech([Float](repeating: 0, count: 1000)), "완전 무음은 음성 없음")
        try expect(!AudioMath.hasSpeech([Float](repeating: 0.002, count: 1000)), "노이즈 플로어는 음성 없음")
        // 피크만 높아도(짧은 발화) true
        try expect(AudioMath.hasSpeech([0.001, 0.2, 0.001]), "피크가 문턱 넘으면 음성 있음")
        // 지속 에너지(RMS)만 높아도 true
        try expect(AudioMath.hasSpeech([Float](repeating: 0.02, count: 1000)), "RMS가 문턱 넘으면 음성 있음")
    }

    await t.test("Audio: crossesSpeechThreshold — peak 또는 rms 중 하나만 넘어도 캡처") {
        // 둘 다 미달 → 캡처 아님(HUD "너무 작음")
        try expect(!AudioMath.crossesSpeechThreshold(AudioLevel(rms: 0.001, peak: 0.005)),
                   "peak·rms 둘 다 문턱 미만이면 캡처 아님")
        // peak만 넘음(이 머신의 조용한 발화 — rms는 낮지만 peak로 통과) → 캡처
        try expect(AudioMath.crossesSpeechThreshold(AudioLevel(rms: 0.0016, peak: 0.0134)),
                   "peak가 문턱 넘으면 rms가 낮아도 캡처")
        // rms만 넘음 → 캡처
        try expect(AudioMath.crossesSpeechThreshold(AudioLevel(rms: 0.004, peak: 0.006)),
                   "rms가 문턱 넘으면 peak가 낮아도 캡처")
        // 경계값(>=) — peak가 정확히 문턱이면 캡처
        try expect(AudioMath.crossesSpeechThreshold(AudioLevel(rms: 0, peak: AudioMath.speechPeakThreshold)),
                   "peak 정확히 문턱이면 캡처(>=)")
    }
}
