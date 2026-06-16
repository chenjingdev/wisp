import Foundation
@testable import WispCore

@MainActor
private func makeClient(scenario: String = "ok") throws -> CodexAppServerClient {
    let script = try unwrap(Bundle.module.url(
        forResource: "mock_codex_server", withExtension: "py", subdirectory: "Fixtures"
    ))
    return CodexAppServerClient(
        executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
        arguments: [script.path],
        environment: ["MOCK_SCENARIO": scenario]
    )
}

@MainActor
func codexClientTests(_ t: TestRunner) async {
    await t.test("CodexClient: 요청-응답 왕복") {
        let client = try makeClient()
        try client.start()
        let result = try await client.request(
            "initialize",
            params: ["clientInfo": ["name": "wisp", "version": "0.1"]],
            timeout: 5
        )
        try expect(result["serverInfo"] != nil, "serverInfo가 있어야 함")
        client.stop()
    }

    await t.test("CodexClient: notification 수신") {
        let client = try makeClient()
        var flag = false
        client.onNotification = { method, params in
            if method == "item/completed",
               let item = params["item"] as? [String: Any],
               item["type"] as? String == "agentMessage" {
                flag = true
            }
        }
        try client.start()
        _ = try await client.request(
            "thread/start",
            params: ["model": "o4-mini", "approvalPolicy": "never",
                     "sandbox": "read-only", "cwd": "/tmp", "ephemeral": true],
            timeout: 5
        )
        _ = try await client.request(
            "turn/start",
            params: ["threadId": "t1", "input": [["type": "text", "text": "hello"]]],
            timeout: 5
        )
        try await waitUntil(timeout: 5) { flag }
        client.stop()
    }

    await t.test("CodexClient: 타임아웃") {
        let client = try makeClient(scenario: "timeout")
        try client.start()
        // thread/start succeeds (returned before 30s sleep)
        _ = try await client.request(
            "thread/start",
            params: ["model": "o4-mini", "approvalPolicy": "never",
                     "sandbox": "read-only", "cwd": "/tmp", "ephemeral": true],
            timeout: 5
        )
        // turn/start responds immediately with inProgress, then server sleeps 30s
        _ = try await client.request(
            "turn/start",
            params: ["threadId": "t1", "input": [["type": "text", "text": "hello"]]],
            timeout: 5
        )
        // send a third request that will time out while server is sleeping
        do {
            _ = try await client.request("initialize", params: [:], timeout: 1)
            try expect(false, "타임아웃 에러가 발생해야 함")
        } catch let e as WispError {
            try expectEqual(e, .codexTimeout)
        }
        client.stop()
    }

    await t.test("CodexClient: 프로세스 크래시 감지") {
        let client = try makeClient(scenario: "crash")
        var terminated = false
        client.onTerminate = { terminated = true }
        try client.start()
        do {
            _ = try await client.request(
                "thread/start",
                params: ["model": "o4-mini", "approvalPolicy": "never",
                         "sandbox": "read-only", "cwd": "/tmp", "ephemeral": true],
                timeout: 5
            )
            try expect(false, "크래시 시 에러가 발생해야 함")
        } catch {
            // expected
        }
        try await waitUntil(timeout: 5) { terminated }
        try expect(!client.isRunning, "프로세스가 종료되어야 함")
    }
}
