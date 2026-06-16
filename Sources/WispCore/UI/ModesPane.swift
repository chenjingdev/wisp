import SwiftUI

struct ModesPane: View {
    @ObservedObject var container: AppContainer
    @State private var selectedId: String?
    @State private var draft: Mode?

    private let languages = [
        ("auto", "자동"), ("ko", "한국어"), ("en", "영어"), ("ja", "일본어"),
        ("zh", "중국어"), ("es", "스페인어"), ("fr", "프랑스어"), ("de", "독일어"),
        ("ru", "러시아어"), ("pt", "포르투갈어"), ("it", "이탈리아어"),
    ]

    var body: some View {
        // HStack(고정폭 목록 + 가변폭 편집기). NavigationSplitView 안에 HSplitView를
        // 중첩하면 편집기가 ideal 너비로 부풀어 창 밖으로 잘리므로 HStack을 쓴다.
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(container.modes, selection: $selectedId) { mode in
                    HStack(spacing: 6) {
                        Text(mode.name)
                        Spacer()
                        // 받아쓰기 중 PTT 보조키를 쥔 채 이 숫자를 누르면 그 프리셋 적용.
                        // 단독 보조키 PTT일 때만 의미가 있어 그 경우에만 배지를 보인다.
                        if container.config.presetHotkeysEnabled,
                           let symbol = container.bareModifierSymbol,
                           let slot = container.modes.firstIndex(where: { $0.id == mode.id }),
                           slot < PresetHotkeys.maxSlots {
                            Text("\(symbol)\(PresetHotkeys.digit(slot: slot))")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        }
                        if mode.id == container.activeModeId {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                    .tag(mode.id)
                }
                Divider()
                HStack(spacing: 12) {
                    Button {
                        if let mode = container.createMode() { selectedId = mode.id }
                    } label: { Image(systemName: "plus") }
                    .disabled(container.modes.count >= PresetHotkeys.maxSlots)   // 최대 10개
                    Button {
                        if let selectedId { container.deleteMode(id: selectedId) }
                        selectedId = nil
                    } label: { Image(systemName: "minus") }
                    .disabled(selectedId == nil || container.modes.count <= 1)   // 최소 1개 유지
                    Spacer()
                    if container.modes.count >= PresetHotkeys.maxSlots {
                        Text("최대 \(PresetHotkeys.maxSlots)개")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(width: 200)

            Divider()

            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("모드")
        .onAppear { selectedId = container.activeModeId }
        .onChange(of: selectedId) { _, newId in
            // 다른 모드로 전환하기 전, 편집 중이던 draft에 미저장 변경이 있으면
            // 조용히 버리지 않고 자동 저장한다(명시적 "저장" 버튼은 그대로 유지).
            if let outgoing = draft,
               let stored = container.modes.first(where: { $0.id == outgoing.id }),
               outgoing != stored {
                container.saveMode(outgoing)
            }
            draft = container.modes.first { $0.id == newId }
        }
    }

    @ViewBuilder
    private var editor: some View {
        // 주의: `Binding($draft)`는 쓰지 않는다. 그 바인딩은 내부적으로 ForceUnwrapping(base!)을
        // 써서, 빈 공간 클릭 등으로 draft가 nil로 바뀌는 순간 — 부모 body가 `if let`을 다시
        // 평가하기 전에 — 살아있는 Form 자식 바인딩이 먼저 갱신되며 nil을 강제 언랩해 크래시한다.
        // 대신 nil이면 마지막 값(current)을 돌려주는 수동 바인딩으로 그 레이스 트랩을 막는다.
        if let current = draft {
            let mode = Binding(get: { draft ?? current }, set: { draft = $0 })
            Form {
                Section {
                    TextField("이름", text: mode.name)
                    Toggle("LLM 후처리", isOn: mode.llmEnabled)
                    Picker("언어", selection: mode.language) {
                        ForEach(languages, id: \.0) { code, label in
                            Text(label).tag(code)
                        }
                    }
                    Toggle("영어로 번역", isOn: mode.translateToEnglish)
                    Picker("녹음 중 오디오", selection: mode.mediaBehavior) {
                        ForEach(MediaBehavior.allCases, id: \.self) { behavior in
                            Text(behavior.displayName).tag(behavior)
                        }
                    }
                }
                Section("프롬프트") {
                    TextEditor(text: mode.prompt)
                        .font(.body)
                        .frame(minHeight: 140)
                }
                if mode.wrappedValue.llmEnabled {
                    Section("컨텍스트 (LLM에 참고로 주입)") {
                        Toggle("선택한 텍스트 포함", isOn: mode.useSelectedText)
                        Toggle("클립보드 내용 포함", isOn: mode.useClipboardContext)
                        Text("녹음 시작 시점의 선택 텍스트·클립보드를 후처리 프롬프트에 참고로 넣습니다 (선택 텍스트는 접근성 권한 필요)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    HStack {
                        Button("저장") {
                            container.saveMode(mode.wrappedValue)
                        }
                        .keyboardShortcut("s")
                        Button("활성 모드로 지정") {
                            container.setActiveMode(mode.wrappedValue.id)
                        }
                        .disabled(mode.wrappedValue.id == container.activeModeId)
                    }
                }
            }
            .formStyle(.grouped)
            .id(current.id)   // 모드 전환 시 편집 서브트리를 교체(이전 모드의 입력 상태 잔존 방지)
        } else {
            Text("모드를 선택하세요").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
