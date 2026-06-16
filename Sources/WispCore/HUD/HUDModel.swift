import Foundation

enum PipelineState: Equatable {
    case idle
    case recording
    case transcribing
    case postProcessing
    case finished
    case failed(String)
}

@MainActor
final class HUDModel: ObservableObject {
    @Published var state: PipelineState = .idle
    @Published var level: Float = 0
    /// 지금 들어오는 소리가 캡처(전사) 문턱을 넘는지 — 넘으면 레벨 막대를 "입력 중" 색으로,
    /// 못 넘으면 "너무 작음" 색으로 그린다. recording 상태에서만 의미.
    @Published var captured: Bool = false
    @Published var notice: String?
    /// 녹음 중 적용될 프리셋(모드) 이름. recording 상태에서만 표시.
    @Published var modeLabel: String?
    /// 파이프라인과 무관한 일회성 안내 (앱 실행/재실행 피드백). idle일 때만 표시.
    @Published var info: String?
}
