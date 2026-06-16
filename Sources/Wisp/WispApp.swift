import SwiftUI
import WispCore

@main
struct WispApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(container: appDelegate.container)
        } label: {
            // 아이콘만으로는 20개 가까운 상태 아이콘 사이에서 식별이 어려움 —
            // 텍스트를 함께 표시해 메뉴바에서 바로 찾을 수 있게 한다
            Image(systemName: "mic.fill")
            Text("Wisp")
        }
        Window("Wisp", id: "main") {
            MainWindowView(container: appDelegate.container)
        }
        .defaultSize(width: 900, height: 600)
    }
}
