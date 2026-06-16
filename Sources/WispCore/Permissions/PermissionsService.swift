import AVFoundation
import ApplicationServices
import AppKit

final class PermissionsService {
    func micStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func micAuthorized() -> Bool {
        micStatus() == .authorized
    }

    func requestMic() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// 손쉬운 사용 권한 부여 여부 (프롬프트 없음).
    func accessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// prompt=true면 시스템 설정 안내 다이얼로그 표시
    func axTrusted(prompt: Bool) -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// 시스템 설정의 손쉬운 사용 창을 연다 (사용자가 직접 토글해야 함).
    @MainActor func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    /// 시스템 설정의 마이크 창을 연다.
    @MainActor func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    @MainActor private func open(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
