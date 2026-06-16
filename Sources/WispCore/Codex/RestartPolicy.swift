import Foundation

/// codex 프로세스 재시작 정책: 지수 백오프, maxAttempts 소진 시 nil (exec 폴백 전용 강등)
struct RestartPolicy {
    private let maxAttempts: Int
    private var attempts = 0

    init(maxAttempts: Int = 3) {
        self.maxAttempts = maxAttempts
    }

    mutating func nextDelay() -> TimeInterval? {
        guard attempts < maxAttempts else { return nil }
        attempts += 1
        return pow(2, Double(attempts - 1))
    }

    mutating func recordSuccess() {
        attempts = 0
    }
}
