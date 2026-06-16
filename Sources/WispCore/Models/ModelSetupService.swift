import Foundation

/// 모델 파일을 카탈로그 URL에서 받아 디스크에 확보한다. 다운로더를 주입할 수 있어
/// (테스트는 mock) 네트워크 없이 동작을 검증한다. 모델은 항상 카탈로그 URL에서 다운로드한다.
final class ModelSetupService {
    /// (다운로드 URL, 진행률 콜백) -> 임시 파일 위치
    typealias Downloader = (URL, @escaping (Double) -> Void) async throws -> URL

    private let downloader: Downloader

    init(downloader: Downloader? = nil) {
        self.downloader = downloader ?? Self.urlSessionDownloader
    }

    /// 모델 확보: 대상 파일이 이미 있으면 그대로, 없으면 url에서 받아 destination으로 옮긴다.
    /// 진행률 콜백은 0.0…1.0 범위로 호출된다(다운로드 시에만).
    @discardableResult
    func ensureModel(destination: URL,
                     downloadURL: URL,
                     progress: @escaping (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { return destination }

        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)

        let tmp = try await downloader(downloadURL, progress)
        do {
            // 중단된 이전 시도가 0바이트 파일을 남겼을 수 있으니 덮어쓴다.
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: tmp, to: destination)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        return destination
    }

    /// 진행률을 실시간으로 보고하는 URLSession 다운로더. delegate의 didWriteData로
    /// 받은 바이트 비율을 콜백한다(콜백은 delegate 큐에서 호출됨 — 호출부에서 메인 디스패치).
    private static let urlSessionDownloader: Downloader = { url, progress in
        let delegate = ProgressDelegate(onProgress: progress)
        let (tmp, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw WispError.modelDownloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        progress(1.0)
        return tmp
    }
}

/// 다운로드 진행률만 전달하는 경량 delegate. 완료 파일은 async download가 반환하므로
/// didFinishDownloadingTo는 비워둔다(프로토콜 요구사항 충족용).
private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }
}
