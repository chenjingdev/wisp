import SwiftUI
import ServiceManagement

struct GeneralPane: View {
    @ObservedObject var container: AppContainer
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("codex LLM 후처리") {
                // 경로/모델은 변경 즉시 저장 + 후처리기 재구성(Enter 없이 포커스 이탈만 해도 반영)
                TextField("바이너리 경로", text: container.binding(\.codexBinaryPath, apply: rebuild))
                HStack {
                    Image(systemName: codexExists ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(codexExists ? .green : .yellow)
                    Text(codexExists ? "실행 파일 확인됨" : "경로에 실행 파일이 없습니다 — LLM 후처리 비활성(원문 붙여넣기)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField("모델", text: container.binding(\.codexModel, apply: rebuild))
                Stepper(value: container.binding(\.llmTimeoutSeconds, apply: rebuild), in: 1...60, step: 1) {
                    Text("타임아웃: \(Int(container.config.llmTimeoutSeconds))초")
                }
            }

            Section("받아쓰기 어휘") {
                // 저장만 하면 다음 받아쓰기부터 적용된다(전사 시 config를 실시간 조회).
                TextEditor(text: container.binding(\.vocabulary))
                    .font(.body).frame(minHeight: 54)
                Text("고유명사·전문용어를 적어두면 인식 정확도가 올라갑니다 (예: Wisp, GRDB, SwiftUI)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("단어 교체") {
                ForEach(container.binding(\.replacements)) { $rule in
                    HStack {
                        TextField("찾기", text: $rule.from)
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                        TextField("바꾸기", text: $rule.to)
                        Button(role: .destructive) {
                            container.config.replacements.removeAll { $0.id == rule.id }
                            container.saveConfig()
                        } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless)
                    }
                }
                Button {
                    container.config.replacements.append(ReplacementRule(from: "", to: ""))
                    container.saveConfig()
                } label: { Label("규칙 추가", systemImage: "plus") }
                .buttonStyle(.borderless)
                Text("전사 후 정확히 일치하는 문자열을 바꿉니다 (대소문자 무시). LLM 후처리 뒤 출력 직전에 적용됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("붙여넣기") {
                Toggle("자동 붙여넣기", isOn: container.binding(\.autoPaste, apply: applyPaste))
                Text("끄면 결과를 클립보드에만 남깁니다 (⌘V로 직접 붙여넣기)")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("입력 방식", selection: container.binding(\.pasteMethod, apply: applyPaste)) {
                    ForEach(PasteMethod.allCases, id: \.self) { method in
                        Text(method.displayName).tag(method)
                    }
                }
                .disabled(!container.config.autoPaste)
                Text("키 입력 시뮬레이션은 ⌘V가 막히는 보안 입력 필드·일부 앱에서 동작합니다 (느림)")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("붙여넣기 후 클립보드 복원", isOn: container.binding(\.restoreClipboard, apply: applyPaste))
                    .disabled(!container.config.autoPaste)
                Text("붙여넣은 뒤 직전 클립보드 내용을 되돌립니다")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("사운드") {
                // RecordingEffectsService가 config를 실시간 조회하므로 저장만 하면 된다.
                Toggle("사운드 피드백 (시작/완료 음)", isOn: container.binding(\.soundFeedback))
            }

            Section("히스토리 자동 정리") {
                Picker("보관 기간", selection: container.binding(\.autoCleanupDays, apply: { container.runAutoCleanup() })) {
                    Text("끔").tag(Int?.none)
                    Text("7일").tag(Int?.some(7))
                    Text("30일").tag(Int?.some(30))
                    Text("90일").tag(Int?.some(90))
                }
                Text("기간이 지난 받아쓰기 기록과 녹음 파일을 앱 시작 시 삭제합니다")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("로그인 시 자동 실행", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("일반")
    }

    private var codexExists: Bool {
        FileManager.default.isExecutableFile(atPath: container.config.codexBinaryPath)
    }

    private func rebuild() { container.rebuildPostProcessor() }
    private func applyPaste() { container.applyPasteSettings() }
}
