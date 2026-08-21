import SwiftUI

struct HotkeyPane: View {
    @ObservedObject var container: AppContainer
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Form {
            Section("받아쓰기 단축키") {
                LabeledContent("현재 단축키") {
                    Button(isRecording ? "키를 누르세요… (Esc 취소)" : container.hotkeyLabel) {
                        isRecording ? stopRecorder() : startRecorder()
                    }
                    .frame(minWidth: 180)
                }
                Text("보조키만 눌렀다 떼면 단독키(예: fn, ⌃), 일반 키와 함께 누르면 조합키(예: ⌥Space)")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Fn은 단독키만 지원하며 Fn+화살표·삭제 같은 macOS 조합에도 Wisp가 잠깐 반응할 수 있습니다. 이모티콘·입력 소스 전환이 겹치면 시스템 설정 → 키보드의 “🌐/fn 키를 눌러” 동작을 “아무것도 안 함”으로 바꾸세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("push-to-talk 판정") {
                Slider(value: container.binding(\.pushToTalkThreshold, apply: { container.reregisterHotkey() }),
                       in: 0.2...1.0, step: 0.05) {
                    Text("임계값")
                } minimumValueLabel: {
                    Text("0.2초")
                } maximumValueLabel: {
                    Text("1.0초")
                }
                Text(String(format: "%.2f초 이상 누르고 있으면 push-to-talk, 그보다 짧으면 토글",
                            container.config.pushToTalkThreshold))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("프리셋 빠른 선택") {
                Toggle("받아쓰기 중 숫자키로 프리셋 선택", isOn: container.binding(\.presetHotkeysEnabled))
                Text("단축키를 누른 채 말하다가 숫자 1…9를 누르면, 모드 목록 순서의 그 프리셋이 이번 받아쓰기의 후처리에 적용됩니다. 손을 떼면 확정됩니다. (단독 보조키 단축키에서 동작)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("트랙패드 트리거") {
                Toggle("트랙패드 손가락 트리거", isOn: trackpadEnabled)
                if container.config.trackpadFingerCount != nil {
                    Picker("손가락 수", selection: trackpadFingers) {
                        Text("3개").tag(3)
                        Text("4개").tag(4)
                        Text("5개").tag(5)
                    }
                }
                Text("지정한 손가락 수를 **길게 누르면** 받아쓰기(push-to-talk), **톡 1번**은 Enter(전송), **톡 2번**은 ⌘Z(방금 받아쓰기 취소). 키보드 단축키와 함께 동작하며, 트랙패드에선 토글 대신 PTT만 동작합니다. 비공개 API 기반이라 macOS 업데이트 후 동작이 바뀔 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("단축키")
        .onDisappear { stopRecorder() }
    }

    /// 트랙패드 트리거 켜기/끄기. 켜면 기본 5손가락, 끄면 nil. 즉시 재등록.
    private var trackpadEnabled: Binding<Bool> {
        Binding(
            get: { container.config.trackpadFingerCount != nil },
            set: { on in
                container.config.trackpadFingerCount = on ? 5 : nil
                container.saveConfig()
                container.reregisterHotkey()
            }
        )
    }

    private var trackpadFingers: Binding<Int> {
        Binding(
            get: { container.config.trackpadFingerCount ?? 5 },
            set: { count in
                container.config.trackpadFingerCount = count
                container.saveConfig()
                container.reregisterHotkey()
            }
        )
    }

    private func startRecorder() {
        isRecording = true
        var capture = HotkeyCapture()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let outcome: HotkeyCapture.Outcome = event.type == .keyDown
                ? capture.handleKeyDown(keyCode: event.keyCode, flags: event.modifierFlags)
                : capture.handleFlagsChanged(flags: event.modifierFlags)
            switch outcome {
            case .combo(let keyCode, let carbonModifiers):
                apply(bare: nil, keyCode: keyCode, modifiers: carbonModifiers)
            case .bareModifier(let name):
                apply(bare: name, keyCode: container.config.hotkeyKeyCode,
                      modifiers: container.config.hotkeyModifiers)
            case .cancelled:
                stopRecorder()
            case .pending, .ignored:
                break
            }
            return nil  // 캡처 중에는 모든 키 이벤트를 소비한다
        }
    }

    private func apply(bare: String?, keyCode: UInt32, modifiers: UInt32) {
        container.config.hotkeyBareModifier = bare
        container.config.hotkeyKeyCode = keyCode
        container.config.hotkeyModifiers = modifiers
        container.saveConfig()
        container.reregisterHotkey()
        stopRecorder()
    }

    private func stopRecorder() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}
