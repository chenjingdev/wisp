import Foundation

/// 자식 프로세스와 newline-delimited JSON으로 통신하는 transport.
final class JSONLProcessTransport: @unchecked Sendable {
    var onMessage: (([String: Any]) -> Void)?
    var onTerminate: (() -> Void)?

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private var buffer = Data()
    private let bufferQueue = DispatchQueue(label: "dev.chenjing.wisp.codex-transport")

    init(executableURL: URL, arguments: [String], environment: [String: String]? = nil) {
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment
                .merging(environment) { _, new in new }
        }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
    }

    var isRunning: Bool { process.isRunning }

    func start() throws {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                // EOF — 핸들러를 해제하지 않으면 빈 데이터로 무한 재호출되어 CPU 스핀
                handle.readabilityHandler = nil
                return
            }
            guard let self else { return }
            self.bufferQueue.async { self.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            self?.stdoutPipe.fileHandleForReading.readabilityHandler = nil
            self?.onTerminate?()
        }
        try process.run()
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                onMessage?(obj)
            }
        }
    }

    func send(_ obj: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: obj)
        data.append(0x0A)
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    func terminate() {
        process.terminationHandler = nil
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }
}
