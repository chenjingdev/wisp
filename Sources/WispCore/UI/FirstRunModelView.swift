import SwiftUI

/// 첫 실행 모델 셋업 화면. 카탈로그(기본값 turbo가 활성)에서 모델을 고르고 다운로드한 뒤
/// "시작하기"로 받아쓰기 엔진을 켠다. 설정 패널과 같은 ModelRowView를 재사용한다.
struct FirstRunModelView: View {
    @ObservedObject var container: AppContainer
    @ObservedObject var manager: ModelManager
    let onStart: () -> Void

    /// 활성 모델이 디스크에 준비됐는지 — "시작하기" 활성화 조건.
    private var activeReady: Bool { manager.isDownloaded(container.activeModel) }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text("받아쓰기 모델 선택").font(.title2.bold())
                Text("음성을 텍스트로 바꾸려면 OpenAI Whisper 모델이 필요합니다.\n기본값(권장)을 받거나 원하는 크기의 변형을 고르세요.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 4)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(manager.catalog) { model in
                        ModelRowView(container: container, manager: manager, model: model)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                        if model.id != manager.catalog.last?.id { Divider() }
                    }
                }
            }
            .frame(height: 290)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))

            Divider()

            HStack {
                if activeReady {
                    Label("\(container.activeModel.displayName) 준비됨", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green).font(.callout)
                } else {
                    Text("선택한 모델을 다운로드하면 시작할 수 있습니다")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("시작하기") { onStart() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!activeReady)
            }
        }
        .padding(24)
        .frame(width: 540)
    }
}

extension FirstRunModelView {
    static let windowContentSize = CGSize(width: 540, height: 520)
}
