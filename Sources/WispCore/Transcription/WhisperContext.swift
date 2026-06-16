import Foundation
import CWhisper

final class WhisperContext {
    private let ctx: OpaquePointer
    /// Silero VAD 모델 경로(있으면 무음 환각 방지용 VAD 활성). nil이면 VAD 미사용.
    private let vadModelPath: String?

    init(modelPath: String, vadModelPath: String? = nil) throws {
        var params = whisper_context_default_params()
        params.use_gpu = true
        guard let ctx = whisper_init_from_file_with_params(modelPath, params) else {
            throw WispError.modelLoadFailed(modelPath)
        }
        self.ctx = ctx
        // 파일이 실제로 있을 때만 VAD 경로를 보관 — 개발 빌드(번들 아님)에선 nil로 강등.
        if let vadModelPath, FileManager.default.fileExists(atPath: vadModelPath) {
            self.vadModelPath = vadModelPath
        } else {
            self.vadModelPath = nil
        }
    }

    deinit { whisper_free(ctx) }

    /// language: "auto"면 자동 감지. prompt: initial_prompt(빈 문자열이면 미사용).
    /// translate: 켜면 영어로 번역. whisper_full은 스레드 안전하지 않음 — 호출자(actor)가 직렬화.
    func transcribe(samples: [Float], language: String, prompt: String, translate: Bool) throws -> String {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.translate = translate
        params.n_threads = Int32(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))

        // VAD(Silero) 켜기 — 무음/비음성 구간은 세그먼트 0개가 돼 디코더가 무음에 아예 돌지
        // 않는다(=`whisper_full`이 빈 결과 → "Thank you"/"감사합니다" 환각 원천 차단). threshold를
        // 기본 0.5보다 낮춰(0.30) 조용한 발화를 무음으로 잘못 버리지 않게 한다(이 머신은 발화
        // 레벨이 매우 낮다). 모델이 없으면(vadModelPath nil) VAD 없이 평소대로 전사한다.
        if vadModelPath != nil {
            params.vad = true
            params.vad_params = whisper_vad_default_params()
            params.vad_params.threshold = 0.30
            params.vad_params.min_speech_duration_ms = 100
            params.vad_params.speech_pad_ms = 60
        }

        // 모든 C 문자열 수명이 whisper_full 호출을 감싸야 한다(중첩 withCString).
        func runFull() -> Int32 {
            language.withCString { lang in
                params.language = lang
                return prompt.withCString { pr in
                    params.initial_prompt = prompt.isEmpty ? nil : pr
                    return samples.withUnsafeBufferPointer { buf in
                        whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
                    }
                }
            }
        }

        let status: Int32
        if let vadModelPath {
            status = vadModelPath.withCString { vp in
                params.vad_model_path = vp
                return runFull()
            }
        } else {
            status = runFull()
        }
        guard status == 0 else { throw WispError.transcriptionFailed(status) }

        // 안전 폴백 — VAD가 아무 음성도 못 찾았으면(세그먼트 0) VAD 없이 1회 재시도한다.
        // 여기 온 오디오는 에너지 게이트(RecordingController)를 "음성 있음"으로 통과한 것이라,
        // 조용한 발화를 VAD가 잘못 버렸을 가능성을 보정해 실제 받아쓰기를 잃지 않는다. 진짜
        // 무음은 에너지 게이트가 앞서 막아 여기 도달하지 않으므로 환각 위험은 낮다.
        // (params.vad=false면 vad_model_path는 참조되지 않으므로 해제된 포인터여도 안전.)
        if vadModelPath != nil && whisper_full_n_segments(ctx) == 0 {
            MultitouchHotkey.diag("VAD: 세그먼트 0 — VAD 없이 재시도(조용한 발화 보정)")
            params.vad = false
            let retry = runFull()
            guard retry == 0 else { throw WispError.transcriptionFailed(retry) }
        }

        var text = ""
        for i in 0..<whisper_full_n_segments(ctx) {
            text += String(cString: whisper_full_get_segment_text(ctx, i))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
