import AppKit

/// 녹음 중 Esc 취소용 전역 키 모니터 (Accessibility 권한 필요)
final class EscMonitor {
    private var monitor: Any?

    func start(onEsc: @escaping () -> Void) {
        stop()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { onEsc() }  // 53 = Esc
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }

    deinit { stop() }
}
