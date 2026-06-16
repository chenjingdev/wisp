import SwiftUI
import AVFoundation

/// 권한 상태를 폴링해 실시간 반영하는 모델. 시스템 설정에서 토글하면 즉시 ✓로 바뀐다.
@MainActor
final class PermissionsModel: ObservableObject {
    @Published var micGranted = false
    @Published var micDenied = false
    @Published var axGranted = false

    private let permissions: PermissionsService

    var allGranted: Bool { micGranted && axGranted }

    init(permissions: PermissionsService) {
        self.permissions = permissions
        refresh()
    }

    func refresh() {
        let status = permissions.micStatus()
        micGranted = status == .authorized
        micDenied = status == .denied || status == .restricted
        axGranted = permissions.accessibilityTrusted()
    }

    /// 마이크: 미결정이면 시스템 프롬프트, 거부 상태면 설정 창으로 안내.
    func handleMic() {
        switch permissions.micStatus() {
        case .notDetermined:
            Task { _ = await permissions.requestMic(); refresh() }
        default:
            permissions.openMicrophoneSettings()
        }
    }

    /// 손쉬운 사용: 프로그램으로 부여 불가 — 시스템 설정 창을 연다.
    func handleAccessibility() {
        _ = permissions.axTrusted(prompt: true)   // 시스템 안내 다이얼로그도 함께
        permissions.openAccessibilitySettings()
    }
}

struct PermissionsView: View {
    @ObservedObject var model: PermissionsModel
    let onDone: () -> Void

    // 시스템 설정에서 토글한 변화를 자동 반영하기 위한 주기적 폴링.
    private let ticker = Timer.publish(every: 0.7, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text("Wisp 시작하기").font(.title2.bold())
                Text("받아쓰기를 쓰려면 두 가지 권한이 필요합니다")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.top, 4)

            VStack(spacing: 10) {
                permissionRow(
                    icon: "mic.fill",
                    title: "마이크",
                    desc: model.micDenied
                        ? "시스템 설정에서 Wisp의 마이크를 켜주세요"
                        : "음성을 녹음해 텍스트로 변환합니다",
                    granted: model.micGranted,
                    actionLabel: model.micDenied ? "설정 열기" : "허용",
                    action: model.handleMic
                )
                permissionRow(
                    icon: "accessibility",
                    title: "손쉬운 사용",
                    desc: "단축키 인식과 자동 붙여넣기에 필요합니다",
                    granted: model.axGranted,
                    actionLabel: "설정 열기",
                    action: model.handleAccessibility
                )
            }

            Divider()

            HStack {
                if model.allGranted {
                    Label("모든 권한이 허용됐습니다", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green).font(.callout)
                } else {
                    Text("설정에서 켜면 자동으로 반영됩니다")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.allGranted ? "시작하기" : "나중에") { onDone() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 440)
        // 시스템 설정에서 토글한 변화를 잡되, 모두 허용된 뒤엔 폴링을 멈춘다.
        .onReceive(ticker) { _ in if !model.allGranted { model.refresh() } }
        .onAppear { model.refresh() }
    }

    @ViewBuilder
    private func permissionRow(icon: String, title: String, desc: String,
                               granted: Bool, actionLabel: String,
                               action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 28, height: 28)
                .foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.title2)
            } else {
                Button(actionLabel, action: action)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}
