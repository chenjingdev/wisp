import SwiftUI
import ServiceManagement
import AppKit
import Combine

struct GeneralPane: View {
    @ObservedObject var container: AppContainer
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// 마이크 테스트용 실시간 레벨 모니터(설정 패널 전용, 받아쓰기와 독립).
    @StateObject private var mic = MicLevelMonitor()
    /// 레벨 미터·슬라이더 상한 — 무음 감지 슬라이더 최댓값과 같은 스케일.
    private let meterMaxScale: Float = 0.06

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

            Section("무음 감지") {
                Slider(value: container.binding(\.speechPeakThreshold, apply: { container.applySpeechThreshold() }),
                       in: 0.005...0.06, step: 0.001) {
                    Text("감도")
                } minimumValueLabel: {
                    Text("민감")
                } maximumValueLabel: {
                    Text("둔감")
                }
                Text(String(format: "녹음 음량(peak)이 %.3f 미만이면 발화 없음으로 보고 전사를 건너뜁니다. 낮출수록 작은 소리도 받아쓰고, 높일수록 또렷한 발화만 받습니다. 아무 말 없이 손만 떼도 “Thank you” 같은 환각이 나오면 높이세요.",
                            container.config.speechPeakThreshold))
                    .font(.caption).foregroundStyle(.secondary)

                // 마이크 테스트 — 실시간 레벨을 보며 문턱(세로선)을 내 목소리·환경에 맞춘다.
                Button(mic.isRunning ? "마이크 테스트 중지" : "마이크 테스트") { mic.toggle() }
                    .buttonStyle(.borderless)
                if mic.isRunning {
                    MicLevelMeter(peak: mic.peakHold,
                                  threshold: container.config.speechPeakThreshold,
                                  maxScale: meterMaxScale)
                    let over = mic.peakHold >= container.config.speechPeakThreshold
                    Text(String(format: "현재 %.4f · 최고 %.4f  —  %@",
                                mic.level.peak, mic.peakHold,
                                over ? "✓ 받아쓰기됨 (문턱 넘음)" : "무음 처리 (문턱 미만)"))
                        .font(.caption)
                        .foregroundStyle(over ? Color.green : .secondary)
                    Text("말해보고 막대가 세로선을 넘는지 확인하세요. 평소 목소리가 안 넘으면 슬라이더를 ‘민감’ 쪽으로, 조용할 때도 넘으면 ‘둔감’ 쪽으로 옮기세요.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
        .onDisappear { mic.stop() }   // 다른 설정 탭으로 전환 시 마이크 점유 해제
        // 창 닫기(빨간 버튼)는 macOS에서 detail 뷰의 onDisappear가 보장되지 않는다 —
        // 창 닫힘 알림으로도 확실히 정지한다(stop은 멱등이라 다른 창 닫힘에 불려도 무해).
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            mic.stop()
        }
    }

    private var codexExists: Bool {
        FileManager.default.isExecutableFile(atPath: container.config.codexBinaryPath)
    }

    private func rebuild() { container.rebuildPostProcessor() }
    private func applyPaste() { container.applyPasteSettings() }
}

/// 입력 peak를 가로 막대로 그리고, 현재 무음 문턱을 세로선으로 표시한다. 막대가 문턱을
/// 넘으면(=받아쓰기 캡처됨) 초록, 미만이면 회색. maxScale은 슬라이더 상한과 같은 스케일.
private struct MicLevelMeter: View {
    let peak: Float
    let threshold: Float
    let maxScale: Float

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fillW = max(2, CGFloat(min(peak, maxScale) / maxScale) * w)
            let markerX = CGFloat(min(threshold, maxScale) / maxScale) * w
            let over = peak >= threshold
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule().fill(over ? Color.green : Color.gray)
                    .frame(width: fillW)
                Rectangle().fill(Color.primary.opacity(0.55))
                    .frame(width: 2)
                    .offset(x: markerX)
            }
        }
        .frame(height: 12)
    }
}
