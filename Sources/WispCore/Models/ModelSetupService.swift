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

    /// 진행률을 실시간으로 보고하는 URLSession 다운로더.
    ///
    /// `URLSession.shared.download(from:delegate:)`의 per-task delegate로는 didWriteData
    /// 증분 콜백이 **오지 않아**(실측 확인) 진행률이 0%에 멈췄다가 끝에야 100%로 튄다. 그래서
    /// **세션 생성 시점에 delegate를 단 전용 URLSession + downloadTask**로 받는다 — 이 경로는
    /// didWriteData가 정상 호출된다. delegate 큐(nil→백그라운드 직렬 큐)에서 콜백되므로
    /// 호출부(ModelManager)가 메인으로 디스패치한다.
    private static let urlSessionDownloader: Downloader = { url, progress in
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let delegate = DownloadProgressDelegate(onProgress: progress, continuation: cont)
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            delegate.session = session   // 끝날 때까지 세션을 살려두고, 완료 시 invalidate로 끊는다
            session.downloadTask(with: url).resume()
        }
    }
}

/// 진행률 콜백 + 완료/실패를 continuation으로 잇는 다운로드 delegate. didFinishDownloadingTo의
/// 임시 파일은 메서드 반환 시 삭제되므로 즉시 안전한 위치로 옮겨 넘긴다.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    /// 세션을 살려두기 위한 강한 참조(세션 ⇄ delegate 순환은 finishTasksAndInvalidate로 끊김).
    var session: URLSession?

    init(onProgress: @escaping (Double) -> Void,
         continuation: CheckedContinuation<URL, Error>) {
        self.onProgress = onProgress
        self.continuation = continuation
    }

    /// continuation은 정확히 한 번만 재개한다(성공 후 didCompleteWithError(nil) 중복 호출 방어).
    private func finish(_ result: Result<URL, Error>, invalidate session: URLSession) {
        session.finishTasksAndInvalidate()
        guard let c = continuation else { return }
        continuation = nil
        c.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(.failure(WispError.modelDownloadFailed("HTTP \(http.statusCode)")), invalidate: session)
            return
        }
        // location은 이 메서드가 반환되는 즉시 사라지므로 동기적으로 옮겨둔다.
        let safe = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisp-model-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: safe)
            onProgress(1.0)
            finish(.success(safe), invalidate: session)
        } catch {
            finish(.failure(error), invalidate: session)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // 성공 시엔 didFinishDownloadingTo에서 이미 처리됨(continuation=nil). 네트워크 실패 등
        // 완료 콜백 없이 끝난 경우만 여기서 실패로 잇는다.
        if let error { finish(.failure(error), invalidate: session) }
    }
}
