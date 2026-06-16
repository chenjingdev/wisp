import Foundation
@testable import WispCore

@MainActor
func restartPolicyTests(_ t: TestRunner) async {
    await t.test("RestartPolicy: 지수 백오프") {
        var policy = RestartPolicy(maxAttempts: 3)
        let d1 = try unwrap(policy.nextDelay())
        try expectEqual(d1, 1.0)
        let d2 = try unwrap(policy.nextDelay())
        try expectEqual(d2, 2.0)
        let d3 = try unwrap(policy.nextDelay())
        try expectEqual(d3, 4.0)
        // 4번째는 한도 초과 → nil
        let d4 = policy.nextDelay()
        try expect(d4 == nil, "maxAttempts 소진 후 nil이어야 함")
    }

    await t.test("RestartPolicy: 성공 시 리셋") {
        var policy = RestartPolicy(maxAttempts: 3)
        _ = policy.nextDelay()
        _ = policy.nextDelay()
        policy.recordSuccess()
        let d1 = try unwrap(policy.nextDelay())
        try expectEqual(d1, 1.0)
    }
}
