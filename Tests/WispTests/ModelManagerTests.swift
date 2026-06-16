import Foundation
@testable import WispCore

@MainActor
func modelManagerTests(_ t: TestRunner) async {
    await t.test("ModelManager: fileURL 파생") {
        try await withTempDir { dir in
            let manager = ModelManager(modelsDir: dir)
            let tiny = ModelCatalog.modelOrDefault(id: "tiny")
            try expectEqual(manager.fileURL(for: tiny).lastPathComponent, "ggml-tiny.bin")
            try expect(!manager.isDownloaded(tiny), "초기엔 없음")
        }
    }

    await t.test("ModelManager: 다운로드 → 디스크 반영") {
        try await withTempDir { dir in
            let model = ModelCatalog.modelOrDefault(id: "tiny")
            let manager = ModelManager(modelsDir: dir, makeService: {
                ModelSetupService(downloader: { _, progress in
                    let tmp = dir.appendingPathComponent("dl-\(UUID().uuidString).bin")
                    try "model-bytes".write(to: tmp, atomically: true, encoding: .utf8)
                    progress(0.4)
                    progress(1.0)
                    return tmp
                })
            })
            let before = manager.diskRevision
            await manager.download(model)
            try expect(manager.isDownloaded(model), "다운로드 후 존재")
            try expect(manager.progress(for: model) == nil, "완료 후 진행률 정리")
            try expect(!manager.isDownloading(model), "다운로드 중 아님")
            try expect(manager.diskRevision > before, "diskRevision 증가")
            try expect((manager.diskSize(of: model) ?? 0) > 0, "파일 크기 > 0")
        }
    }

    await t.test("ModelManager: 이미 받은 모델은 재다운로드 안 함") {
        try await withTempDir { dir in
            let model = ModelCatalog.modelOrDefault(id: "tiny")
            let dest = dir.appendingPathComponent(model.fileName)
            try "orig".write(to: dest, atomically: true, encoding: .utf8)

            var called = false
            let manager = ModelManager(modelsDir: dir, makeService: {
                ModelSetupService(downloader: { _, _ in
                    called = true
                    throw WispError.modelDownloadFailed("호출되면 안 됨")
                })
            })
            await manager.download(model)
            try expect(!called, "다운로더가 호출되면 안 됨")
            try expectEqual(try String(contentsOf: dest, encoding: .utf8), "orig")
        }
    }

    await t.test("ModelManager: 다운로드 실패는 에러 기록") {
        try await withTempDir { dir in
            let model = ModelCatalog.modelOrDefault(id: "tiny")
            let manager = ModelManager(modelsDir: dir, makeService: {
                ModelSetupService(downloader: { _, _ in
                    throw WispError.modelDownloadFailed("HTTP 500")
                })
            })
            await manager.download(model)
            try expect(!manager.isDownloaded(model), "실패 시 파일 없음")
            try expect(manager.progress(for: model) == nil, "진행률 정리")
            try expect(manager.downloadError[model.id] != nil, "에러 메시지 기록")
        }
    }

    await t.test("ModelManager: 삭제") {
        try await withTempDir { dir in
            let model = ModelCatalog.modelOrDefault(id: "base")
            let dest = dir.appendingPathComponent(model.fileName)
            try "x".write(to: dest, atomically: true, encoding: .utf8)

            let manager = ModelManager(modelsDir: dir)
            try expect(manager.isDownloaded(model), "사전 조건")
            let before = manager.diskRevision
            manager.delete(model)
            try expect(!manager.isDownloaded(model), "삭제 후 없음")
            try expect(manager.diskRevision > before, "diskRevision 증가")
        }
    }
}
