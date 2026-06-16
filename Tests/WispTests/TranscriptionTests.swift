import Foundation
@testable import WispCore

@MainActor
func transcriptionTests(_ t: TestRunner) async {
    await t.test("Transcription: 영어 fixture 골든") {
        let modelURL = AppPaths.modelURL
        if !FileManager.default.fileExists(atPath: modelURL.path) {
            try skip("모델 없음 — Task 6 Step 1 실행 필요")
            return
        }
        let wavURL = try unwrap(
            Bundle.module.url(forResource: "english", withExtension: "wav", subdirectory: "Fixtures")
        )
        let samples = try WavReader.readMono16k(url: wavURL)
        let service = TranscriptionService(modelURL: modelURL)
        let text = try await service.transcribe(samples: samples, language: "en")
        try expect(text.lowercased().contains("quick brown fox"), "전사 결과: \(text)")
    }
}
