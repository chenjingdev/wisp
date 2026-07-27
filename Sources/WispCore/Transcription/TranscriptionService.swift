import Foundation

actor TranscriptionService: Transcribing {
    private let modelURL: URL
    private let vadModelURL: URL?
    private var context: WhisperContext?
    private static let keepWarmSamples = [Float](repeating: 0, count: 16_000)

    init(modelURL: URL, vadModelURL: URL? = nil) {
        self.modelURL = modelURL
        self.vadModelURL = vadModelURL
    }

    /// 앱 시작 시 백그라운드에서 호출해 모델을 미리 로드
    func warmUp() throws {
        if context == nil {
            context = try WhisperContext(modelPath: modelURL.path, vadModelPath: vadModelURL?.path)
        }
    }

    /// 실제 whisper_full 경로까지 한 번 돌려 Metal/VAD lazy init과 압축 해제 지연을 미리 치른다.
    func keepWarm(language: String) throws {
        try warmUp()
        guard let context else { throw WispError.modelLoadFailed(modelURL.path) }
        try context.keepWarm(samples: Self.keepWarmSamples, language: language)
    }

    func transcribe(samples: [Float], language: String, prompt: String, translate: Bool) async throws -> String {
        guard !samples.isEmpty else { throw WispError.emptyTranscript }
        try warmUp()
        guard let context else { throw WispError.modelLoadFailed(modelURL.path) }
        return try context.transcribe(samples: samples, language: language, prompt: prompt, translate: translate)
    }
}
