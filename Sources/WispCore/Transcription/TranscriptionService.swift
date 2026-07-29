import Foundation

actor TranscriptionService: Transcribing {
    private let modelURL: URL
    private let vadModelURL: URL?
    private var context: WhisperContext?
    private static let primingSamples = [Float](repeating: 0, count: 16_000)

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

    /// 앱 시작/모델 전환 때 한 번만 실제 경로를 짧게 돌려 Metal/VAD lazy init 비용을 치른다.
    /// 주기적으로 호출하지 않는다.
    func primeInference(language: String) throws {
        try warmUp()
        guard let context else { throw WispError.modelLoadFailed(modelURL.path) }
        try context.primeInference(samples: Self.primingSamples, language: language)
    }

    /// 사용자가 녹음을 시작한 순간, 이미 로드된 모델 가중치의 Metal residency를 다시 요청한다.
    /// 더미 오디오 전사와 달리 compute graph를 실행하지 않으므로 실제 전사를 오래 막지 않는다.
    func prepareForRecording() async throws {
        try warmUp()
        guard let context else { throw WispError.modelLoadFailed(modelURL.path) }
        context.requestResidency()
    }

    func transcribe(samples: [Float], language: String, prompt: String, translate: Bool) async throws -> String {
        guard !samples.isEmpty else { throw WispError.emptyTranscript }
        try warmUp()
        guard let context else { throw WispError.modelLoadFailed(modelURL.path) }
        return try context.transcribe(samples: samples, language: language, prompt: prompt, translate: translate)
    }
}
