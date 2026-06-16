import Foundation
@testable import WispCore

@MainActor
func modeStoreTests(_ t: TestRunner) async {
    await t.test("ModeStore: 기본 모드 3종 시딩") {
        try await withTempDir { dir in
            let store = ModeStore(directory: dir)
            try store.seedDefaultsIfNeeded()
            let modes = try store.loadAll()
            let ids = Set(modes.map(\.id))
            try expectEqual(ids, Set(["dictation", "message", "email"]))
            let dictation = try unwrap(try store.mode(id: "dictation"))
            try expectEqual(dictation.llmEnabled, false)
            let message = try unwrap(try store.mode(id: "message"))
            try expectEqual(message.llmEnabled, true)
        }
    }

    await t.test("ModeStore: 시딩이 사용자 수정 안 덮어씀") {
        try await withTempDir { dir in
            let store = ModeStore(directory: dir)
            try store.seedDefaultsIfNeeded()
            var message = try unwrap(try store.mode(id: "message"))
            message.prompt = "커스텀 프롬프트"
            try store.save(message)
            // Seed again — should NOT overwrite existing file
            try store.seedDefaultsIfNeeded()
            let reloaded = try unwrap(try store.mode(id: "message"))
            try expectEqual(reloaded.prompt, "커스텀 프롬프트")
        }
    }

    await t.test("ModeStore: 없는 모드는 nil") {
        try await withTempDir { dir in
            let store = ModeStore(directory: dir)
            let result = try store.mode(id: "nope")
            try expectEqual(result, nil)
        }
    }

    await t.test("ModeStore: create는 고유 id로 생성·저장") {
        try await withTempDir { dir in
            let store = ModeStore(directory: dir)
            let a = try store.create()
            let b = try store.create()
            try expect(a.id != b.id, "id가 고유해야 함")
            try expectEqual(a.name, "새 모드")
            try expectEqual(a.llmEnabled, true)
            let loaded = try unwrap(try store.mode(id: a.id))
            try expectEqual(loaded, a)
        }
    }

    await t.test("ModeStore: mediaBehavior 왕복 + 구버전 파일은 .pause") {
        try await withTempDir { dir in
            let store = ModeStore(directory: dir)
            // 기본 모드는 .pause
            try store.seedDefaultsIfNeeded()
            try expectEqual(try unwrap(try store.mode(id: "dictation")).mediaBehavior, .pause)

            // 왕복 (mediaBehavior + translateToEnglish + 컨텍스트 토글)
            var m = try unwrap(try store.mode(id: "message"))
            m.mediaBehavior = .duck
            m.translateToEnglish = true
            m.useSelectedText = true
            m.useClipboardContext = true
            try store.save(m)
            let roundtrip = try unwrap(try store.mode(id: "message"))
            try expectEqual(roundtrip.mediaBehavior, .duck)
            try expectEqual(roundtrip.translateToEnglish, true)
            try expectEqual(roundtrip.useSelectedText, true)
            try expectEqual(roundtrip.useClipboardContext, true)

            // 신규 키가 없는 구버전 파일 → 기본값으로 디코딩 (실패 아님)
            let legacy = #"""
            {"id":"legacy","name":"옛모드","prompt":"p","llmEnabled":true,"language":"ko"}
            """#
            try legacy.write(to: dir.appendingPathComponent("legacy.json"),
                             atomically: true, encoding: .utf8)
            let loaded = try unwrap(try store.mode(id: "legacy"))
            try expectEqual(loaded.mediaBehavior, .pause)
            try expectEqual(loaded.translateToEnglish, false)
            try expectEqual(loaded.useSelectedText, false)
            try expectEqual(loaded.useClipboardContext, false)
            try expectEqual(loaded.language, "ko")  // 기존 필드 보존
        }
    }

    await t.test("ModeStore: delete는 커스텀·기본 모드 모두 삭제") {
        try await withTempDir { dir in
            let store = ModeStore(directory: dir)
            try store.seedDefaultsIfNeeded()
            let custom = try store.create()

            // 커스텀 삭제
            try store.delete(id: custom.id)
            try expectEqual(try store.mode(id: custom.id), nil)

            // 기본 모드도 삭제 가능 (전부 동등)
            try store.delete(id: "dictation")
            try expectEqual(try store.mode(id: "dictation"), nil)
            // 나머지는 남음
            try expect(try store.mode(id: "message") != nil, "다른 모드는 유지")
        }
    }

    await t.test("ModeStore: 모드가 남아 있으면 시딩이 지운 기본 모드를 되살리지 않음") {
        try await withTempDir { dir in
            let store = ModeStore(directory: dir)
            try store.seedDefaultsIfNeeded()
            try store.delete(id: "email")
            // 다른 모드가 있으니(디렉터리 비지 않음) 재시딩 안 함 → email 그대로 삭제 상태
            try store.seedDefaultsIfNeeded()
            try expectEqual(try store.mode(id: "email"), nil)

            // 전부 지워 비면 다음 시딩에서 기본 3종 복구
            try store.delete(id: "dictation")
            try store.delete(id: "message")
            try store.seedDefaultsIfNeeded()
            try expectEqual(Set(try store.loadAll().map(\.id)), Set(["dictation", "message", "email"]))
        }
    }
}
