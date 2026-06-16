import SwiftUI

/// 설정 창의 "모델" 섹션. 카탈로그를 목록으로 보여주고 선택·다운로드·삭제를 제공한다.
struct ModelsPane: View {
    @ObservedObject var container: AppContainer
    @ObservedObject var manager: ModelManager

    var body: some View {
        Form {
            Section {
                ForEach(manager.catalog) { model in
                    ModelRowView(container: container, manager: manager, model: model)
                }
            } header: {
                Text("OpenAI Whisper · 받아쓰기 모델")
            } footer: {
                Text("받아쓰기 모델은 OpenAI Whisper 하나이며, 아래는 그 크기·버전별 변형입니다 "
                     + "(클수록 정확하지만 느리고 용량이 큽니다). HuggingFace에서 다운로드되고, "
                     + "이미 받은 변형으로 바꾸면 즉시 적용됩니다. 사용하지 않는 모델은 삭제해 용량을 회수할 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("모델")
    }
}
