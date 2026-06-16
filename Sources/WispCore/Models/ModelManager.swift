import Foundation

/// 모델 카탈로그의 디스크 상태와 다운로드를 관리하는 뷰모델. UI(ModelsPane·첫 실행 창)가
/// 관찰하고, 실제 다운로드는 주입된 ModelSetupService에 위임한다. 순수 카탈로그 로직은
/// ModelCatalog에 있고, 여기는 @Published 상태 배선만 담당한다(테스트는 mock 다운로더 주입).
@MainActor
final class ModelManager: ObservableObject {
    let catalog: [WhisperModel]
    private let modelsDir: URL
    private let makeService: () -> ModelSetupService

    /// 진행 중 다운로드 진행률(id -> 0.0…1.0). 키가 없으면 다운로드 중이 아니다.
    @Published private(set) var downloadProgress: [String: Double] = [:]
    /// 마지막 다운로드 실패 메시지(id -> 사유). 성공/재시도 시 지워진다.
    @Published private(set) var downloadError: [String: String] = [:]
    /// 디스크 상태(파일 존재)가 바뀔 때 증가 — isDownloaded는 FileManager로 직접 조회하므로
    /// 다운로드 완료/삭제 후 뷰를 다시 그리게 하는 트리거로 쓴다.
    @Published private(set) var diskRevision = 0

    init(catalog: [WhisperModel] = ModelCatalog.all,
         modelsDir: URL = AppPaths.models,
         makeService: @escaping () -> ModelSetupService = { ModelSetupService() }) {
        self.catalog = catalog
        self.modelsDir = modelsDir
        self.makeService = makeService
    }

    /// 모델 파일의 디스크 경로.
    func fileURL(for model: WhisperModel) -> URL {
        modelsDir.appendingPathComponent(model.fileName)
    }

    /// 모델이 디스크에 받아져 있는지.
    func isDownloaded(_ model: WhisperModel) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: model).path)
    }

    /// 다운로드 진행 중인지.
    func isDownloading(_ model: WhisperModel) -> Bool {
        downloadProgress[model.id] != nil
    }

    /// 진행률(0.0…1.0). 다운로드 중이 아니면 nil.
    func progress(for model: WhisperModel) -> Double? {
        downloadProgress[model.id]
    }

    /// 다운로드된 모델의 실제 파일 크기(바이트). 없으면 nil.
    func diskSize(of model: WhisperModel) -> Int64? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL(for: model).path)
        return (attrs?[.size] as? NSNumber)?.int64Value
    }

    /// 모델을 카탈로그 URL에서 다운로드한다. 이미 받았거나 진행 중이면 무시.
    /// 진행률/에러는 @Published로 노출돼 UI가 즉시 반영한다.
    func download(_ model: WhisperModel) async {
        guard downloadProgress[model.id] == nil, !isDownloaded(model) else { return }
        downloadError[model.id] = nil
        downloadProgress[model.id] = 0
        do {
            try await makeService().ensureModel(
                destination: fileURL(for: model),
                downloadURL: ModelCatalog.downloadURL(for: model),
                progress: { [weak self] p in
                    // 진행률 콜백은 URLSession delegate 큐에서 올 수 있어 메인으로 디스패치.
                    Task { @MainActor in self?.downloadProgress[model.id] = p }
                }
            )
            downloadProgress[model.id] = nil
            diskRevision += 1
        } catch {
            downloadProgress[model.id] = nil
            downloadError[model.id] = error.localizedDescription
        }
    }

    /// 다운로드된 모델을 삭제해 용량을 회수한다.
    func delete(_ model: WhisperModel) {
        try? FileManager.default.removeItem(at: fileURL(for: model))
        diskRevision += 1
    }
}
