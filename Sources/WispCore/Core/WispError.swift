import Foundation

enum WispError: LocalizedError, Equatable {
    case modelLoadFailed(String)
    case modelDownloadFailed(String)
    case audioSetupFailed
    case emptyTranscript
    case codexUnavailable(String)
    case codexTimeout
    case codexRPC(String)
    case transcriptionFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let path): return "모델 로드 실패: \(path)"
        case .modelDownloadFailed(let reason): return "모델 다운로드 실패: \(reason)"
        case .audioSetupFailed: return "오디오 입력을 초기화하지 못했습니다"
        case .emptyTranscript: return "음성이 인식되지 않았습니다"
        case .codexUnavailable(let reason): return "codex 사용 불가: \(reason)"
        case .codexTimeout: return "codex 응답 시간 초과"
        case .codexRPC(let message): return "codex 오류: \(message)"
        case .transcriptionFailed(let code): return "전사 실패 (whisper 상태 \(code))"
        }
    }
}
