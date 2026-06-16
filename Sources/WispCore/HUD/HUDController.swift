import AppKit
import SwiftUI

@MainActor
final class HUDController {
    let model = HUDModel()
    private var panel: NSPanel?
    private var flashTask: Task<Void, Never>?
    /// "캡처 중" 판정 peak 문턱 — 설정(무음 감지 감도)과 동기화돼 전사 게이트와 같은 기준을 쓴다.
    var speechPeakThreshold: Float = AudioMath.speechPeakThreshold

    func update(state: PipelineState, notice: String? = nil) {
        model.state = state
        model.notice = notice
        if state != .recording {
            model.modeLabel = nil   // 녹음 밖에선 프리셋 라벨 정리
            model.captured = false  // 다음 녹음이 "너무 작음"에서 깨끗이 시작하게
            quietStreak = 0
        }
        switch state {
        case .idle:
            if model.info == nil { hide() }  // 실행 안내 플래시 중이면 유지
        default:
            show()
        }
    }

    /// 녹음 중 적용될 프리셋(모드) 라벨 설정. recording 상태에서만 보인다.
    func setModeLabel(_ name: String?) {
        model.modeLabel = name
    }

    /// 파이프라인과 무관한 일회성 안내 표시 (앱 실행/재실행 피드백 등).
    func flash(_ message: String, seconds: Double = 2.5) {
        flashTask?.cancel()
        model.info = message
        show()
        flashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.model.info = nil
            if self.model.state == .idle { self.hide() }
        }
    }

    /// 레벨 미터용 적응형 정규화. 마이크 게인이 환경마다 크게 달라(이 머신은 발화 RMS가
    /// ~0.0016로 매우 낮다) 고정 스케일은 막대가 아예 안 켜지거나 항상 꽉 찬다. 최근
    /// 최댓값(빠르게 오르고 천천히 감쇠)에 상대적으로 정규화해 어떤 마이크에서도 음성에
    /// 반응하게 만든다. 결과는 0~1.
    private var levelCeiling: Float = 0.004
    /// 문턱 미달 청크가 연속 몇 개째인지 — 단어 사이 짧은 공백에 "너무 작음"으로 깜빡이지
    /// 않도록 grace(2청크 ≈ 0.5s)를 둔다.
    private var quietStreak = 0
    func update(level: AudioLevel) {
        // 막대 높이는 rms(지속 에너지, 부드러움)로 그린다. 마이크 게인이 환경마다 크게 달라
        // 고정 스케일은 막대가 안 켜지거나 항상 꽉 차므로 최근 최댓값에 상대 정규화한다.
        let rms = level.rms
        let floor: Float = 0.0008                              // 노이즈 플로어 — 이 밑은 0
        // 천장: 현재 레벨로 즉시 상승, 아니면 천천히 감쇠(최소 floor*5로 바닥 방지).
        levelCeiling = max(rms, max(floor * 5, levelCeiling * 0.9))
        model.level = min(1, max(0, (rms - floor)) / max(0.0001, levelCeiling - floor))

        // 캡처 상태는 절대 문턱(peak 또는 rms)으로 판정 — 적응 정규화와 무관하게 "받아쓰기될
        // 만큼 큰가"를 답한다. 한 청크라도 넘으면 즉시 켜고, 미달은 grace 뒤에 끈다.
        if AudioMath.crossesSpeechThreshold(level, peakThreshold: speechPeakThreshold) {
            quietStreak = 0
            model.captured = true
        } else {
            quietStreak += 1
            if quietStreak >= 2 { model.captured = false }
        }
    }

    private func show() {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        reposition(panel)
        panel.orderFrontRegardless()
    }

    private func reposition(_ panel: NSPanel) {
        // 멀티 모니터: 사용자가 보고 있을 가능성이 가장 높은 마우스 포인터가 있는
        // 화면에 표시한다 (NSScreen.main은 백그라운드 앱에선 사실상 주 모니터 고정).
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        if let screen {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.minY + 80
            ))
        }
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        // 패널은 HUDView의 고정 크기 투명 컨테이너와 동일 크기로 만든다.
        // 알약 배경은 SwiftUI가 콘텐츠 크기로만 그리므로 여백은 보이지 않는다.
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: HUDView.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        // statusBar(25)는 런처/어시스턴트류 오버레이 창에 가려진다 — popUpMenu(101)로
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hosting = NSHostingView(rootView: HUDView(model: model))
        // 기본 sizingOptions(.standardBounds)는 패널을 SwiftUI 계산 크기로 강제
        // 리사이즈해 긴 안내 문구가 창 경계에서 잘린다 — 고정 크기 패널을 쓴다.
        hosting.sizingOptions = []
        panel.contentView = hosting
        return panel
    }
}
