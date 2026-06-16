import Foundation
@testable import WispCore

@MainActor
func modelCatalogTests(_ t: TestRunner) async {
    await t.test("ModelCatalog: 7개 모델, id 유일") {
        try expectEqual(ModelCatalog.all.count, 7)
        let ids = ModelCatalog.all.map { $0.id }
        try expectEqual(Set(ids).count, ids.count, "id가 유일해야 함")
        // 스펙 카탈로그 항목이 모두 존재
        for id in ["large-v3-turbo", "large-v3-turbo-q5_0", "large-v3",
                   "medium", "small", "base", "tiny"] {
            try expect(ModelCatalog.model(id: id) != nil, "\(id) 누락")
        }
    }

    await t.test("ModelCatalog: 기본 모델은 large-v3-turbo") {
        try expectEqual(ModelCatalog.defaultModelId, "large-v3-turbo")
        try expectEqual(ModelCatalog.defaultModel.id, "large-v3-turbo")
        try expectEqual(ModelCatalog.defaultModel.fileName, "ggml-large-v3-turbo.bin")
    }

    await t.test("ModelCatalog: 알 수 없는 id 폴백") {
        try expect(ModelCatalog.model(id: "nope") == nil)
        try expectEqual(ModelCatalog.modelOrDefault(id: "nope").id, ModelCatalog.defaultModelId)
        try expectEqual(ModelCatalog.modelOrDefault(id: "tiny").id, "tiny")
    }

    await t.test("ModelCatalog: 다운로드 URL은 HF resolve 경로") {
        let turbo = try unwrap(ModelCatalog.model(id: "large-v3-turbo"))
        try expectEqual(
            ModelCatalog.downloadURL(for: turbo).absoluteString,
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
        )
        let tiny = try unwrap(ModelCatalog.model(id: "tiny"))
        try expectEqual(
            ModelCatalog.downloadURL(for: tiny).absoluteString,
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin"
        )
    }

    await t.test("ModelCatalog: 크기 포맷(10진)") {
        try expectEqual(ModelCatalog.humanSize(1_600_000_000), "~1.6GB")
        try expectEqual(ModelCatalog.humanSize(547_000_000), "~547MB")
        try expectEqual(ModelCatalog.humanSize(3_100_000_000), "~3.1GB")
        try expectEqual(ModelCatalog.humanSize(78_000_000), "~78MB")
        // 모델 메타데이터의 sizeText도 같은 포맷
        try expectEqual(ModelCatalog.defaultModel.sizeText, "~1.6GB")
    }

    await t.test("ModelCatalog: 모두 다국어") {
        for model in ModelCatalog.all {
            try expect(model.multilingual, "\(model.id)는 다국어여야 함")
        }
    }
}
