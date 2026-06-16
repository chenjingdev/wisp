import Foundation

/// 다운로드 가능한 whisper.cpp 모델 1종의 메타데이터. 순수 값 타입 — 카탈로그·선택·
/// 경로 파생 로직을 네트워크/디스크 없이 단위테스트할 수 있게 한다.
struct WhisperModel: Identifiable, Equatable, Sendable {
    /// 안정적인 식별자(config에 저장). 표시명이 바뀌어도 선택은 유지된다.
    let id: String
    /// 설정 화면에 보여줄 사람용 이름.
    let displayName: String
    /// HuggingFace 저장소의 파일명 = 디스크에 저장할 파일명.
    let fileName: String
    /// 대략적인 다운로드 크기(바이트, 10진 단위). 실제 파일 크기와 다를 수 있다.
    let approxBytes: Int64
    /// 다국어 지원 여부(.en 전용 변형은 카탈로그에 넣지 않아 현재 모두 true).
    let multilingual: Bool
    /// 속도/정확도 등 특징 한 줄 요약.
    let note: String

    /// "~1.6GB" 같은 사람용 크기 표시.
    var sizeText: String { ModelCatalog.humanSize(approxBytes) }
}

/// whisper 모델 카탈로그 + 선택·경로 파생 순수 로직.
enum ModelCatalog {
    /// 모든 모델은 ggerganov/whisper.cpp 저장소의 main 리비전에서 받는다.
    static let baseURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"

    /// 첫 실행 기본 선택 모델(빠르고 정확한 다국어 turbo).
    static let defaultModelId = "large-v3-turbo"

    /// 표시 순서 = 권장/큰 것 → 작은 것.
    static let all: [WhisperModel] = [
        WhisperModel(id: "large-v3-turbo", displayName: "large-v3-turbo",
                     fileName: "ggml-large-v3-turbo.bin", approxBytes: 1_600_000_000,
                     multilingual: true, note: "809M · 다국어 · 빠르고 정확 (권장)"),
        WhisperModel(id: "large-v3-turbo-q5_0", displayName: "large-v3-turbo-q5_0",
                     fileName: "ggml-large-v3-turbo-q5_0.bin", approxBytes: 547_000_000,
                     multilingual: true, note: "809M · q5_0 양자화 — 작고 빠름"),
        WhisperModel(id: "large-v3", displayName: "large-v3",
                     fileName: "ggml-large-v3.bin", approxBytes: 3_100_000_000,
                     multilingual: true, note: "1550M · 다국어 · 최고 정확도 (느림)"),
        WhisperModel(id: "medium", displayName: "medium",
                     fileName: "ggml-medium.bin", approxBytes: 1_500_000_000,
                     multilingual: true, note: "769M · 다국어 · 정확도와 속도 절충"),
        WhisperModel(id: "small", displayName: "small",
                     fileName: "ggml-small.bin", approxBytes: 488_000_000,
                     multilingual: true, note: "244M · 다국어 · 가벼움"),
        WhisperModel(id: "base", displayName: "base",
                     fileName: "ggml-base.bin", approxBytes: 148_000_000,
                     multilingual: true, note: "74M · 다국어 · 빠름"),
        WhisperModel(id: "tiny", displayName: "tiny",
                     fileName: "ggml-tiny.bin", approxBytes: 78_000_000,
                     multilingual: true, note: "39M · 다국어 · 가장 빠름 (정확도 낮음)"),
    ]

    /// 기본 모델(존재가 보장된 카탈로그 상수).
    static var defaultModel: WhisperModel { model(id: defaultModelId)! }

    /// id로 모델 조회. 알 수 없는 id(구버전·삭제된 카탈로그 항목)면 nil.
    static func model(id: String) -> WhisperModel? {
        all.first { $0.id == id }
    }

    /// 알 수 없는 id면 기본 모델로 폴백 — UI/엔진이 항상 유효한 모델을 갖도록.
    static func modelOrDefault(id: String) -> WhisperModel {
        model(id: id) ?? defaultModel
    }

    /// 모델의 HuggingFace 다운로드 URL.
    static func downloadURL(for model: WhisperModel) -> URL {
        URL(string: baseURL + model.fileName)!
    }

    /// 10진(1000) 단위 사람용 크기 — 로케일/플랫폼에 무관하게 결정적이라 테스트 가능.
    static func humanSize(_ bytes: Int64) -> String {
        let gb = 1_000_000_000.0
        let mb = 1_000_000.0
        let b = Double(bytes)
        if b >= gb {
            return String(format: "~%.1fGB", b / gb)
        }
        return String(format: "~%.0fMB", b / mb)
    }
}
