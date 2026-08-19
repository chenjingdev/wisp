import AppKit
import SwiftUI

/// 권한 온보딩 창을 관리한다. 메뉴바 전용(accessory) 앱이라 SwiftUI Window scene을
/// 프로그램적으로 띄우기 번거로워, HUDController처럼 NSWindow를 직접 띄운다.
@MainActor
final class OnboardingController {
    private var window: NSWindow?
    let model: PermissionsModel

    init(permissions: PermissionsService) {
        self.model = PermissionsModel(permissions: permissions)
    }

    /// 권한이 하나라도 빠졌으면 온보딩 창을 띄운다 (시작 시 호출).
    func showIfNeeded() {
        model.refresh()
        if !model.allGranted { show() }
    }

    func show() {
        if window == nil {
            let view = PermissionsView(model: model) { [weak self] in self?.close() }
            let hosting = NSHostingView(rootView: view)
            hosting.sizingOptions = []
            hosting.frame = NSRect(origin: .zero, size: PermissionsView.windowContentSize)
            let win = NSWindow(
                contentRect: NSRect(origin: .zero, size: PermissionsView.windowContentSize),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            win.title = "Wisp"
            win.isReleasedWhenClosed = false
            win.contentMinSize = PermissionsView.windowContentSize
            win.contentMaxSize = PermissionsView.windowContentSize
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
