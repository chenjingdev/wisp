import Foundation

/// codex app-server로 STT 원문을 후처리. 실패 시 재시작 → exec 폴백 → 원문 반환.
actor PostProcessService: PostProcessing {
    typealias ExecFallback = (String) async throws -> String

    private let makeClient: () -> CodexAppServerClient
    private let model: String
    private let timeout: TimeInterval
    private let execFallback: ExecFallback
    private let restartDelayScale: Double

    private var client: CodexAppServerClient?
    private var initialized = false
    private var restartPolicy = RestartPolicy(maxAttempts: 3)
    private var awaiting: (threadId: String,
                           continuation: CheckedContinuation<String, Error>)?
    private var timeoutTask: Task<Void, Never>?
    private var lastAgentMessage: String?
    /// 단일 소비자 notification 펌프 — 도착 순서대로 actor에서 처리 (per-notification Task hop 금지)
    private var notificationContinuation: AsyncStream<(String, [String: Any])>.Continuation?
    private var pumpTask: Task<Void, Never>?

    init(makeClient: @escaping () -> CodexAppServerClient,
         model: String,
         timeout: TimeInterval,
         execFallback: ExecFallback? = nil,
         restartDelayScale: Double = 1.0) {
        self.makeClient = makeClient
        self.model = model
        self.timeout = timeout
        self.execFallback = execFallback ?? { _ in
            throw WispError.codexUnavailable("execFallback 미설정")
        }
        self.restartDelayScale = restartDelayScale
    }

    // MARK: - PostProcessing

    func process(transcript: String, mode: Mode, context: DictationContext) async -> PostProcessOutcome {
        guard mode.llmEnabled else {
            return PostProcessOutcome(
                finalText: transcript, llmOutput: nil, llmSucceeded: true, llmSeconds: 0
            )
        }
        let prompt = Self.buildPrompt(mode: mode, transcript: transcript, context: context)
        let start = Date()

        // 1차: app-server (실패 시 재시작 후 1회 재시도)
        for attempt in 0..<2 {
            do {
                if attempt > 0 { try await restart() }
                let text = try await runViaAppServer(prompt: prompt)
                restartPolicy.recordSuccess()
                return PostProcessOutcome(
                    finalText: text, llmOutput: text, llmSucceeded: true,
                    llmSeconds: Date().timeIntervalSince(start)
                )
            } catch {
                NSLog("Wisp: app-server 시도 \(attempt + 1) 실패 — \(error)")
            }
        }

        // 2차: codex exec 단발
        do {
            let text = try await execFallback(prompt)
            return PostProcessOutcome(
                finalText: text, llmOutput: text, llmSucceeded: true,
                llmSeconds: Date().timeIntervalSince(start)
            )
        } catch {
            NSLog("Wisp: exec 폴백 실패 — \(error)")
        }

        // 3차: 원문 그대로 (입력 무손실)
        return PostProcessOutcome(
            finalText: transcript, llmOutput: nil, llmSucceeded: false,
            llmSeconds: Date().timeIntervalSince(start)
        )
    }

    static func buildPrompt(mode: Mode, transcript: String, context: DictationContext) -> String {
        var parts: [String] = [mode.prompt]
        if mode.useSelectedText,
           let sel = context.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines), !sel.isEmpty {
            parts.append("[참고 — 사용자가 선택한 텍스트]\n\(sel)")
        }
        if mode.useClipboardContext,
           let clip = context.clipboardText?.trimmingCharacters(in: .whitespacesAndNewlines), !clip.isEmpty {
            parts.append("[참고 — 현재 클립보드 내용]\n\(clip)")
        }
        parts.append("""
            다음 받아쓰기 원문을 위 지침에 따라 다듬어라. 결과 텍스트만 출력하고 다른 말은 하지 마라.

            원문:
            \(transcript)
            """)
        return parts.joined(separator: "\n\n")
    }

    // MARK: - app-server 경로

    private func ensureClient() async throws -> CodexAppServerClient {
        if let client, client.isRunning, initialized { return client }
        teardownPump()

        let client = makeClient()
        // transport가 bufferQueue에서 onMessage를 직렬 호출 → yield가 도착 순서를 보존한다.
        let (stream, continuation) = AsyncStream<(String, [String: Any])>.makeStream()
        notificationContinuation = continuation
        client.onNotification = { method, params in
            continuation.yield((method, params))
        }
        // 턴 도중 codex 프로세스가 죽으면 turn/completed가 영영 안 오므로 즉시 실패시킨다.
        client.onTerminate = { [weak self] in
            Task {
                await self?.failAwaiting(
                    threadId: nil, error: WispError.codexUnavailable("프로세스 종료됨")
                )
            }
        }
        // 소비자가 단 하나라 actor hop이 있어도 처리 순서가 보존된다.
        pumpTask = Task { [weak self] in
            for await (method, params) in stream {
                await self?.handleNotification(method: method, params: params)
            }
        }
        try client.start()
        _ = try await client.request(
            CodexProtocol.initialize,
            params: ["clientInfo": ["name": "wisp", "version": "0.1.0"]],
            timeout: timeout
        )
        try client.notify(CodexProtocol.initializedNotification)
        self.client = client
        initialized = true
        return client
    }

    private func teardownPump() {
        notificationContinuation?.finish()
        notificationContinuation = nil
        pumpTask?.cancel()
        pumpTask = nil
    }

    private func restart() async throws {
        client?.stop()
        client = nil
        initialized = false
        teardownPump()
        guard let delay = restartPolicy.nextDelay() else {
            throw WispError.codexUnavailable("재시작 한도 초과")
        }
        try await Task.sleep(nanoseconds: UInt64(delay * restartDelayScale * 1_000_000_000))
    }

    private func runViaAppServer(prompt: String) async throws -> String {
        let client = try await ensureClient()
        let threadResult = try await client.request(
            CodexProtocol.threadStart,
            params: [
                "model": model,
                "approvalPolicy": "never",
                "sandbox": "read-only",
                "cwd": FileManager.default.temporaryDirectory.path,
                "ephemeral": true,
            ],
            timeout: timeout
        )
        guard let thread = threadResult["thread"] as? [String: Any],
              let threadId = thread["id"] as? String else {
            throw WispError.codexRPC("thread.id 없음: \(threadResult)")
        }

        return try await performTurn(client: client, threadId: threadId, prompt: prompt)
    }

    /// turn/start를 보내고 같은 thread의 turn/completed까지 대기.
    /// 타임아웃·요청 실패·프로세스 종료 중 무엇이 먼저든 awaiting을 직접 실패시켜 행이 없다.
    private func performTurn(client: CodexAppServerClient, threadId: String,
                             prompt: String) async throws -> String {
        lastAgentMessage = nil
        return try await withCheckedThrowingContinuation { continuation in
            // actor 격리 내에서 동기 실행 — turn/start 전송 전에 awaiting 등록 보장
            awaiting = (threadId, continuation)
            timeoutTask = Task { [timeout] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self.failAwaiting(threadId: threadId, error: WispError.codexTimeout)
            }
            Task {
                do {
                    _ = try await client.request(
                        CodexProtocol.turnStart,
                        params: [
                            "threadId": threadId,
                            "input": [["type": "text", "text": prompt]],
                            "effort": "low",
                        ],
                        timeout: self.timeout
                    )
                } catch {
                    await self.failAwaiting(threadId: threadId, error: error)
                }
            }
        }
    }

    /// threadId nil이면 무조건 실패(프로세스 종료 등), 아니면 같은 스레드일 때만.
    private func failAwaiting(threadId: String?, error: Error) {
        guard let current = awaiting else { return }
        if let threadId, current.threadId != threadId { return }
        awaiting = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        current.continuation.resume(throwing: error)
    }

    private func handleNotification(method: String, params: [String: Any]) {
        guard let awaiting else { return }
        // 다른(이전) 스레드의 잔류 이벤트가 현재 대기를 오염시키지 않도록 필터링
        if let eventThreadId = params["threadId"] as? String,
           eventThreadId != awaiting.threadId {
            return
        }

        switch method {
        case CodexProtocol.itemCompleted:
            if let item = params["item"] as? [String: Any],
               item["type"] as? String == CodexProtocol.agentMessageType,
               let text = item["text"] as? String {
                lastAgentMessage = text
            }
        case CodexProtocol.turnCompleted:
            self.awaiting = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            let status = (params["turn"] as? [String: Any])?["status"] as? String
            if status == "completed",
               let text = lastAgentMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                awaiting.continuation.resume(returning: text)
            } else {
                awaiting.continuation.resume(
                    throwing: WispError.codexRPC("턴 종료 상태: \(status ?? "unknown"), 텍스트 없음")
                )
            }
        default:
            break
        }
    }

    // MARK: - exec 폴백 (실제 구현; 조립은 Task 17)

    static func makeRealExecFallback(codexPath: String, model: String) -> ExecFallback {
        { prompt in
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    let outFile = FileManager.default.temporaryDirectory
                        .appendingPathComponent("wisp-codex-\(UUID().uuidString).txt")
                    defer { try? FileManager.default.removeItem(at: outFile) }

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: codexPath)
                    process.arguments = [
                        "exec", "--skip-git-repo-check", "-m", model, "-s", "read-only",
                        "--output-last-message", outFile.path, prompt,
                    ]
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    do {
                        try process.run()
                    } catch {
                        return continuation.resume(
                            throwing: WispError.codexUnavailable("exec 실행 실패: \(error)")
                        )
                    }
                    let deadline = Date().addingTimeInterval(15)
                    while process.isRunning && Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                    if process.isRunning {
                        process.terminate()
                        process.waitUntilExit() // 좀비 프로세스 방지
                        return continuation.resume(throwing: WispError.codexTimeout)
                    }
                    guard let text = try? String(contentsOf: outFile, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                        !text.isEmpty
                    else {
                        return continuation.resume(throwing: WispError.codexRPC("exec 빈 출력"))
                    }
                    continuation.resume(returning: text)
                }
            }
        }
    }
}
