import AppKit
import SwiftUI

/// 첫 실행/모델 부재 시 모델 선택·다운로드 창을 관리한다. 권한 온보딩(OnboardingController)과
/// 같은 방식으로 NSWindow를 직접 띄운다(메뉴바 전용 accessory 앱이라 Window scene이 번거로움).
@MainActor
final class ModelSetupController {
    private var window: NSWindow?
    private weak var container: AppContainer?
    private var onReady: (() -> Void)?

    init(container: AppContainer) {
        self.container = container
    }

    /// 셋업 창을 띄운다. 활성 모델이 준비되고 "시작하기"를 누르면 onReady를 1회 호출하고 닫는다.
    func show(onReady: @escaping () -> Void) {
        self.onReady = onReady
        if window == nil, let container {
            let view = FirstRunModelView(container: container, manager: container.modelManager) { [weak self] in
                self?.onReady?()
                self?.close()
            }
            let hosting = NSHostingView(rootView: view)
            hosting.sizingOptions = []
            hosting.frame = NSRect(origin: .zero, size: FirstRunModelView.windowContentSize)
            let win = NSWindow(
                contentRect: NSRect(origin: .zero, size: FirstRunModelView.windowContentSize),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            win.title = "Wisp — 모델 다운로드"
            win.isReleasedWhenClosed = false
            win.contentMinSize = FirstRunModelView.windowContentSize
            win.contentMaxSize = FirstRunModelView.windowContentSize
            win.contentView = hosting
            win.center()
            window = win
        }
        // accessory 앱은 명시적으로 활성화해야 창이 앞으로 와 키 입력을 받는다.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }
}
