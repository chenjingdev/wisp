import Foundation

actor TranscriptionService: Transcribing {
    private let modelURL: URL
    private let vadModelURL: URL?
    private var context: WhisperContext?

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

    func transcribe(samples: [Float], language: String, prompt: String, translate: Bool) async throws -> String {
        guard !samples.isEmpty else { throw WispError.emptyTranscript }
        try warmUp()
        guard let context else { throw WispError.modelLoadFailed(modelURL.path) }
        return try context.transcribe(samples: samples, language: language, prompt: prompt, translate: translate)
    }
}
