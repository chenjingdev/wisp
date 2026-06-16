import Foundation

/// codex app-server JSON-RPC 메서드/이벤트 이름 (codex-cli 0.128.0 실측 — docs/codex/NOTES.md)
enum CodexProtocol {
    static let initialize = "initialize"
    static let initializedNotification = "initialized"
    static let threadStart = "thread/start"
    static let turnStart = "turn/start"
    static let itemCompleted = "item/completed"
    static let turnCompleted = "turn/completed"
    static let agentMessageType = "agentMessage"
}
