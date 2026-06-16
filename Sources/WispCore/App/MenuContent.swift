import SwiftUI

public struct MenuContent: View {
    @ObservedObject var container: AppContainer
    @Environment(\.openWindow) private var openWindow

    public init(container: AppContainer) {
        self.container = container
    }

    public var body: some View {
        Text(container.statusText)
        Divider()
        Picker("모드", selection: Binding(
            get: { container.activeModeId },
            set: { container.setActiveMode($0) }
        )) {
            ForEach(container.modes) { mode in
                Text(mode.name).tag(mode.id)
            }
        }
        .pickerStyle(.inline)
        Divider()
        Button("Wisp 열기…") {
            openWindow(id: "main")
            // LSUIElement 앱은 명시적으로 활성화해야 창이 앞으로 온다
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("마지막 결과 복사") { container.copyLastResult() }
        Button("권한 설정…") { container.openOnboarding() }
        Divider()
        Button("종료") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
