import Foundation
@testable import WispCore

@MainActor
func modelSetupServiceTests(_ t: TestRunner) async {
    await t.test("ModelSetup: 기존 모델 있으면 다운로드 안 함") {
        try await withTempDir { tempDir in
            let dest = tempDir.appendingPathComponent("model.bin")
            try "existing-model".write(to: dest, atomically: true, encoding: .utf8)

            let svc = ModelSetupService(downloader: { _, _ in
                try expect(false, "다운로드 불필요")
                fatalError()
            })
            let result = try await svc.ensureModel(
                destination: dest,
                downloadURL: URL(string: "https://example.com/model.bin")!,
                progress: { _ in }
            )
            try expectEqual(result, dest)
        }
    }

    await t.test("ModelSetup: 없으면 카탈로그 URL에서 다운로드") {
        try await withTempDir { tempDir in
            let dest = tempDir.appendingPathComponent("model.bin")
            let downloadedTmp = tempDir.appendingPathComponent("downloaded-tmp.bin")
            try "downloaded-model".write(to: downloadedTmp, atomically: true, encoding: .utf8)

            var receivedURL: URL?
            var lastProgress = 0.0
            let svc = ModelSetupService(downloader: { url, progress in
                receivedURL = url
                progress(0.5)
                progress(1.0)
                return downloadedTmp
            })
            let result = try await svc.ensureModel(
                destination: dest,
                downloadURL: URL(string: "https://example.com/model.bin")!,
                progress: { lastProgress = $0 }
            )
            try expectEqual(result, dest)
            try expectEqual(receivedURL, URL(string: "https://example.com/model.bin")!)
            try expectEqual(lastProgress, 1.0)
            try expect(FileManager.default.fileExists(atPath: dest.path), "dest가 존재해야 함")
            let content = try String(contentsOf: dest, encoding: .utf8)
            try expectEqual(content, "downloaded-model")
        }
    }

    await t.test("ModelSetup: 대상 폴더가 없어도 생성 후 다운로드") {
        try await withTempDir { tempDir in
            // models 하위 폴더가 아직 없는 상태 — ensureModel이 만들어야 한다.
            let dest = tempDir.appendingPathComponent("models/sub/model.bin")
            let downloadedTmp = tempDir.appendingPathComponent("tmp.bin")
            try "fresh".write(to: downloadedTmp, atomically: true, encoding: .utf8)

            let svc = ModelSetupService(downloader: { _, _ in downloadedTmp })
            let result = try await svc.ensureModel(
                destination: dest,
                downloadURL: URL(string: "https://example.com/model.bin")!,
                progress: { _ in }
            )
            try expectEqual(result, dest)
            try expect(FileManager.default.fileExists(atPath: dest.path), "중첩 폴더에 dest 생성")
        }
    }

    await t.test("ModelSetup: 다운로더 실패는 전파되고 dest는 없음") {
        try await withTempDir { tempDir in
            let dest = tempDir.appendingPathComponent("model.bin")
            let svc = ModelSetupService(downloader: { _, _ in
                throw WispError.modelDownloadFailed("HTTP 404")
            })
            var threw = false
            do {
                _ = try await svc.ensureModel(
                    destination: dest,
                    downloadURL: URL(string: "https://example.com/model.bin")!,
                    progress: { _ in }
                )
            } catch {
                threw = true
            }
            try expect(threw, "다운로드 실패가 전파돼야 함")
            try expect(!FileManager.default.fileExists(atPath: dest.path), "실패 시 dest가 없어야 함")
        }
    }
}
