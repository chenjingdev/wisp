import Foundation

/// codex 바이너리 경로를 자동으로 찾는다. 설치 위치는 사용자·머신마다 다르므로(Homebrew는
/// Apple Silicon `/opt/homebrew`, Intel `/usr/local`, npm 전역·asdf·bun 등) 하드코딩된
/// 기본값(`/opt/homebrew/bin/codex`)만으로는 다른 컴퓨터에서 클론하면 LLM 후처리가 그냥
/// 꺼진다. 다음 순서로 해석한다:
///   1. 설정에 지정된 경로가 실행 가능하면 그대로(사용자 지정 우선)
///   2. 로그인 셸의 PATH에서 `command -v codex` (Homebrew·npm·asdf·nvm·bun 등 포괄)
///   3. 흔한 고정 설치 위치
/// 찾은 경로가 설정과 다르면 호출부가 설정에 저장해, 다음 실행부턴 1단계에서 바로 끝난다.
///
/// codex의 **인증 토큰**은 codex CLI가 사용자별로 따로 관리하므로(`codex login`) 여기서
/// 다루지 않는다 — 우리는 바이너리 위치만 찾으면 된다.
enum CodexLocator {
    static var commonPaths: [String] {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin/codex",       // Homebrew (Apple Silicon)
            "/usr/local/bin/codex",          // Homebrew (Intel) / 수동 설치
            "\(home)/.codex/bin/codex",      // codex 자체 설치본
            "\(home)/.local/bin/codex",      // pipx/사용자 로컬
            "\(home)/.bun/bin/codex",        // bun 전역
            "\(home)/.npm-global/bin/codex", // npm 전역(커스텀 prefix)
        ]
    }

    /// 순수 해석 로직 — 파일 존재·셸 조회를 주입받아 테스트 가능. 못 찾으면 nil.
    static func resolve(configured: String,
                        common: [String] = commonPaths,
                        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                        shellWhich: () -> String? = loginShellWhich) -> String? {
        if !configured.isEmpty, fileExists(configured) { return configured }
        if let viaShell = shellWhich(), fileExists(viaShell) { return viaShell }
        return common.first(where: fileExists)
    }

    /// 로그인 셸을 띄워 PATH 상의 codex를 찾는다(`-l`이라 ~/.zprofile 등의 PATH 설정을 반영).
    /// 설정 경로가 이미 유효하면 resolve가 이 단계를 건너뛰므로, 보통 다른 머신 첫 실행에서만
    /// 1회 실행된다(이후 탐지 결과가 설정에 저장돼 더는 셸을 띄우지 않는다).
    static func loginShellWhich() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-lc", "command -v codex"]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return nil }
        // 여러 줄(별칭/함수 등)일 수 있으니 마지막 줄을 쓰고, 절대 경로일 때만 채택한다.
        let last = raw.split(separator: "\n").last.map(String.init) ?? raw
        return last.hasPrefix("/") ? last : nil
    }
}
