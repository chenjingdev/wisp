import Foundation

/// JSON-RPC 요청/응답 상관관계와 notification 라우팅을 담당.
final class CodexAppServerClient: @unchecked Sendable {
    var onNotification: ((String, [String: Any]) -> Void)?
    var onTerminate: (() -> Void)?

    private let transport: JSONLProcessTransport
    private let lock = NSLock()
    private var nextId = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    init(executableURL: URL, arguments: [String], environment: [String: String]? = nil) {
        transport = JSONLProcessTransport(
            executableURL: executableURL, arguments: arguments, environment: environment
        )
        transport.onMessage = { [weak self] message in self?.handle(message) }
        transport.onTerminate = { [weak self] in
            self?.failAllPending(with: WispError.codexUnavailable("프로세스 종료됨"))
            self?.onTerminate?()
        }
    }

    var isRunning: Bool { transport.isRunning }

    func start() throws { try transport.start() }

    func stop() {
        transport.terminate()
        failAllPending(with: WispError.codexUnavailable("클라이언트 중지"))
    }

    func request(_ method: String, params: [String: Any],
                 timeout: TimeInterval) async throws -> [String: Any] {
        let id: Int = {
            lock.lock(); defer { lock.unlock() }
            nextId += 1
            return nextId
        }()

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pending[id] = continuation
            lock.unlock()

            let client = self
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                client.takePending(id: id)?.resume(throwing: WispError.codexTimeout)
            }

            do {
                try transport.send([
                    "jsonrpc": "2.0", "id": id, "method": method, "params": params,
                ])
            } catch {
                takePending(id: id)?.resume(throwing: WispError.codexUnavailable("\(error)"))
            }
        }
    }

    /// 응답 없는 JSON-RPC notification 전송 (예: initialized)
    func notify(_ method: String, params: [String: Any] = [:]) throws {
        try transport.send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func handle(_ message: [String: Any]) {
        if let id = message["id"] as? Int {
            guard let continuation = takePending(id: id) else { return }
            if let error = message["error"] as? [String: Any] {
                let text = error["message"] as? String ?? "\(error)"
                continuation.resume(throwing: WispError.codexRPC(text))
            } else {
                continuation.resume(returning: message["result"] as? [String: Any] ?? [:])
            }
        } else if let method = message["method"] as? String {
            onNotification?(method, message["params"] as? [String: Any] ?? [:])
        }
    }

    private func takePending(id: Int) -> CheckedContinuation<[String: Any], Error>? {
        lock.lock(); defer { lock.unlock() }
        return pending.removeValue(forKey: id)
    }

    private func failAllPending(with error: Error) {
        lock.lock()
        let all = pending
        pending.removeAll()
        lock.unlock()
        all.values.forEach { $0.resume(throwing: error) }
    }
}
