import Foundation

/// Phase 1용: LLM 없이 STT 원문을 그대로 통과
struct PassthroughPostProcessor: PostProcessing {
    func process(transcript: String, mode: Mode, context: DictationContext) async -> PostProcessOutcome {
        PostProcessOutcome(finalText: transcript, llmOutput: nil, llmSucceeded: true, llmSeconds: 0)
    }
}
