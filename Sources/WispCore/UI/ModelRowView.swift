import SwiftUI

/// 카탈로그 모델 1행. 설정 패널(ModelsPane)과 첫 실행 창(FirstRunModelView)이 공유한다.
/// 다운로드 여부·크기·진행률을 보여주고, 선택/다운로드/삭제 동작을 제공한다.
struct ModelRowView: View {
    @ObservedObject var container: AppContainer
    @ObservedObject var manager: ModelManager
    let model: WhisperModel

    private var isActive: Bool { container.config.whisperModelId == model.id }
    private var downloaded: Bool { manager.isDownloaded(model) }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName).font(.body.weight(.medium))
                    if isActive {
                        Text("활성")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.green.opacity(0.2), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                Text(model.note).font(.caption).foregroundStyle(.secondary)
                if let error = manager.downloadError[model.id] {
                    Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer()
            Text(sizeText)
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            trailing
        }
        .padding(.vertical, 2)
    }

    /// 받아진 모델은 실제 파일 크기, 아니면 카탈로그 대략 크기.
    private var sizeText: String {
        if let bytes = manager.diskSize(of: model) { return ModelCatalog.humanSize(bytes) }
        return model.sizeText
    }

    @ViewBuilder
    private var trailing: some View {
        if let progress = manager.progress(for: model) {
            HStack(spacing: 6) {
                ProgressView(value: progress).frame(width: 90)
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
        } else if downloaded {
            HStack(spacing: 8) {
                if isActive {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("선택") { container.selectModel(model.id) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                // 활성 모델은 엔진이 사용 중이라 삭제 불가 — 그 외엔 용량 회수 허용.
                Button(role: .destructive) { manager.delete(model) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless).controlSize(.small)
                .disabled(isActive)
                .help(isActive ? "활성 모델은 삭제할 수 없습니다" : "모델 삭제")
            }
        } else {
            Button("다운로드") { Task { await manager.download(model) } }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
    }
}
