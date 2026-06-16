import Foundation

// CLT 전용 환경(XCTest 부재)을 위한 초소형 테스트 하네스.
// 사용: ./scripts/test.sh [이름 필터]

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    let file: StaticString
    let line: UInt
    var description: String { "\(file):\(line) — \(message)" }
}

struct TestSkip: Error {
    let reason: String
}

func expect(_ condition: Bool, _ message: String = "expectation failed",
            file: StaticString = #filePath, line: UInt = #line) throws {
    if !condition { throw TestFailure(message: message, file: file, line: line) }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "",
                               file: StaticString = #filePath, line: UInt = #line) throws {
    if actual != expected {
        throw TestFailure(
            message: "\(message.isEmpty ? "" : message + " — ")\"\(actual)\" != \"\(expected)\"",
            file: file, line: line
        )
    }
}

func expectEqual(_ actual: Float, _ expected: Float, accuracy: Float,
                 file: StaticString = #filePath, line: UInt = #line) throws {
    if abs(actual - expected) > accuracy {
        throw TestFailure(message: "\(actual) != \(expected) (±\(accuracy))", file: file, line: line)
    }
}

func unwrap<T>(_ value: T?, _ message: String = "nil이 아니어야 함",
               file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { throw TestFailure(message: message, file: file, line: line) }
    return value
}

func skip(_ reason: String) throws {
    throw TestSkip(reason: reason)
}

/// 비동기 조건 충족 대기 (XCTest expectation 대체)
func waitUntil(timeout: TimeInterval = 5, interval: TimeInterval = 0.05,
               _ message: String = "waitUntil 시간 초과",
               file: StaticString = #filePath, line: UInt = #line,
               _ condition: @escaping () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
    throw TestFailure(message: message, file: file, line: line)
}

/// 테스트별 임시 디렉토리 (XCTest setUp/tearDown 대체)
func withTempDir<T>(_ body: (URL) async throws -> T) async throws -> T {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wisp-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try await body(dir)
}

@MainActor
final class TestRunner {
    private(set) var passed = 0
    private(set) var failed = 0
    private(set) var skipped = 0
    private let filter: String?

    init(filter: String?) {
        self.filter = filter
    }

    func test(_ name: String, _ body: @MainActor () async throws -> Void) async {
        if let filter, !name.localizedCaseInsensitiveContains(filter) { return }
        do {
            try await body()
            passed += 1
            print("PASS \(name)")
        } catch let skipped as TestSkip {
            self.skipped += 1
            print("SKIP \(name): \(skipped.reason)")
        } catch {
            failed += 1
            print("FAIL \(name)\n     \(error)")
        }
    }

    func finish() -> Never {
        print("\n\(passed) passed, \(failed) failed, \(skipped) skipped")
        exit(failed == 0 && passed + skipped > 0 ? 0 : 1)
    }
}
