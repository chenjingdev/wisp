import SwiftUI

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 10) {
            switch model.state {
            case .idle:
                if let info = model.info {
                    Image(systemName: "mic.fill").foregroundStyle(.secondary)
                    // fixedSize: NSHostingView가 패널을 최소 폭까지 줄여 텍스트를
                    // 자르는 것을 방지 (전체 문구 폭만큼 패널이 늘어난다)
                    Text(info).font(.caption)
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    EmptyView()
                }
            case .recording:
                Image(systemName: "mic.fill").foregroundStyle(.red)
                LevelBars(level: model.level, captured: model.captured)
                if let mode = model.modeLabel {
                    Text(mode).font(.caption).fontWeight(.medium)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Text("Esc 취소").font(.caption2).foregroundStyle(.secondary)
            case .transcribing:
                ProgressView().controlSize(.small)
                Text("전사 중…").font(.caption)
            case .postProcessing:
                ProgressView().controlSize(.small)
                Text("다듬는 중…").font(.caption)
            case .finished:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                if let notice = model.notice {
                    Text(notice).font(.caption)
                        .fixedSize(horizontal: true, vertical: false)
                }
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(message).font(.caption).lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .frame(minWidth: 160)
        // 패널과 동일한 고정 크기 투명 컨테이너에 알약을 중앙 정렬.
        // NSHostingView/NSPanel의 콘텐츠 기반 크기 계산(긴 문구 잘림의 원인)을 차단한다.
        .frame(width: HUDView.panelSize.width, height: HUDView.panelSize.height)
    }
}

extension HUDView {
    static let panelSize = CGSize(width: 520, height: 60)
}

private struct LevelBars: View {
    let level: Float
    /// 지금 소리가 캡처(전사) 문턱을 넘는지. 점등 막대 색을 가른다:
    /// 넘으면 green("입력 중 — 받아쓰기됨"), 못 넘으면 중립 회색("너무 작음 — 무음 처리").
    let captured: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<8, id: \.self) { i in
                let threshold = Float(i + 1) / 8  // level은 HUDController가 0~1로 적응형 정규화
                RoundedRectangle(cornerRadius: 1)
                    .fill(level > threshold ? litColor : Color.secondary.opacity(0.25))
                    .frame(width: 3, height: 4 + CGFloat(i) * 2)
            }
        }
        .animation(.easeOut(duration: 0.1), value: level)      // 막대 점등이 부드럽게 따라오게
        .animation(.easeOut(duration: 0.15), value: captured)  // 색 전환도 부드럽게
    }

    private var litColor: Color { captured ? .green : .secondary }
}
