import Foundation
@testable import WispCore

@MainActor
func configStoreTests(_ t: TestRunner) async {
    await t.test("ConfigStore: 파일 없으면 기본값") {
        try await withTempDir { dir in
            let store = ConfigStore(url: dir.appendingPathComponent("config.json"))
            let config = store.load()
            let defaults = WispConfig()
            try expectEqual(config, defaults)
            try expectEqual(config.hotkeyKeyCode, UInt32(49))
            try expectEqual(config.hotkeyModifiers, UInt32(2048))
            try expectEqual(config.pushToTalkThreshold, 0.4)
        }
    }

    await t.test("ConfigStore: 저장 후 로드 왕복") {
        try await withTempDir { dir in
            let url = dir.appendingPathComponent("config.json")
            let store1 = ConfigStore(url: url)
            var config = store1.load()
            config.activeModeId = "email"
            config.llmTimeoutSeconds = 5
            try store1.save(config)

            let store2 = ConfigStore(url: url)
            let loaded = store2.load()
            try expectEqual(loaded.activeModeId, "email")
            try expectEqual(loaded.llmTimeoutSeconds, 5.0)
            try expectEqual(loaded, config)
        }
    }

    await t.test("ConfigStore: 손상 파일이면 기본값") {
        try await withTempDir { dir in
            let url = dir.appendingPathComponent("config.json")
            try "not json".write(to: url, atomically: true, encoding: .utf8)
            let store = ConfigStore(url: url)
            let config = store.load()
            try expectEqual(config, WispConfig())
        }
    }

    await t.test("ConfigStore: autoCleanupDays 왕복 + 구버전 호환") {
        try await withTempDir { dir in
            let url = dir.appendingPathComponent("config.json")
            let store = ConfigStore(url: url)

            // 기본값은 nil (끔)
            try expectEqual(store.load().autoCleanupDays, Int?.none)

            // 왕복
            var config = store.load()
            config.autoCleanupDays = 30
            try store.save(config)
            try expectEqual(store.load().autoCleanupDays, Int?.some(30))

            // autoCleanupDays만 없는 완전한 구버전 파일 → 기존 설정은 보존되고
            // 새 필드만 nil로 디코딩돼야 한다. (필수 키가 빠진 JSON은 디코딩
            // 실패→전체 기본값 폴백이라 이 호환성을 증명하지 못한다)
            let legacy = #"""
            {"hotkeyKeyCode":49,"hotkeyModifiers":2048,"hotkeyBareModifier":"control",
             "pushToTalkThreshold":0.4,"activeModeId":"email",
             "codexBinaryPath":"/opt/homebrew/bin/codex",
             "codexModel":"gpt-5.3-codex-spark","llmTimeoutSeconds":10}
            """#
            try legacy.write(to: url, atomically: true, encoding: .utf8)
            let migrated = store.load()
            try expectEqual(migrated.autoCleanupDays, Int?.none)
            try expectEqual(migrated.activeModeId, "email")  // 폴백이 아닌 진짜 디코딩 증명
        }
    }

    await t.test("ConfigStore: autoPaste/restoreClipboard/soundFeedback 왕복") {
        try await withTempDir { dir in
            let url = dir.appendingPathComponent("config.json")
            let store = ConfigStore(url: url)

            // 기본값
            let defaults = store.load()
            try expectEqual(defaults.autoPaste, true)
            try expectEqual(defaults.restoreClipboard, false)
            try expectEqual(defaults.soundFeedback, true)
            try expectEqual(defaults.presetHotkeysEnabled, true)

            var config = store.load()
            config.autoPaste = false
            config.restoreClipboard = true
            config.soundFeedback = false
            config.presetHotkeysEnabled = false
            try store.save(config)

            let loaded = store.load()
            try expectEqual(loaded.autoPaste, false)
            try expectEqual(loaded.restoreClipboard, true)
            try expectEqual(loaded.soundFeedback, false)
            try expectEqual(loaded.presetHotkeysEnabled, false)
        }
    }

    await t.test("ConfigStore: 신규 필드 없는 구버전 파일도 기존 설정 보존") {
        try await withTempDir { dir in
            let url = dir.appendingPathComponent("config.json")
            let store = ConfigStore(url: url)
            // autoPaste/restoreClipboard/soundFeedback/autoCleanupDays 모두 없는 구버전
            let legacy = #"""
            {"hotkeyKeyCode":49,"hotkeyModifiers":2048,"hotkeyBareModifier":"option",
             "pushToTalkThreshold":0.6,"activeModeId":"message",
             "codexBinaryPath":"/custom/codex","codexModel":"gpt-x","llmTimeoutSeconds":7}
            """#
            try legacy.write(to: url, atomically: true, encoding: .utf8)
            let c = store.load()
            // 기존 설정 보존 (전체 기본값 리셋 아님)
            try expectEqual(c.hotkeyBareModifier, "option")
            try expectEqual(c.pushToTalkThreshold, 0.6)
            try expectEqual(c.activeModeId, "message")
            try expectEqual(c.codexBinaryPath, "/custom/codex")
            // 신규 필드는 기본값
            try expectEqual(c.autoPaste, true)
            try expectEqual(c.restoreClipboard, false)
            try expectEqual(c.soundFeedback, true)
            try expectEqual(c.presetHotkeysEnabled, true)
            try expectEqual(c.vocabulary, "")
            try expectEqual(c.replacements, [])
            try expectEqual(c.pasteMethod, .clipboard)
        }
    }

    await t.test("ConfigStore: whisperModelId 왕복 + 구버전 호환") {
        try await withTempDir { dir in
            let url = dir.appendingPathComponent("config.json")
            let store = ConfigStore(url: url)

            // 기본값 = large-v3-turbo
            try expectEqual(store.load().whisperModelId, ModelCatalog.defaultModelId)
            try expectEqual(store.load().whisperModelId, "large-v3-turbo")

            // 왕복
            var config = store.load()
            config.whisperModelId = "small"
            try store.save(config)
            try expectEqual(store.load().whisperModelId, "small")

            // whisperModelId만 없는 구버전 파일 → 새 필드만 기본값, 기존 설정은 보존
            let legacy = #"""
            {"hotkeyKeyCode":49,"hotkeyModifiers":2048,"hotkeyBareModifier":"control",
             "pushToTalkThreshold":0.4,"activeModeId":"email",
             "codexBinaryPath":"/opt/homebrew/bin/codex",
             "codexModel":"gpt-5.3-codex-spark","llmTimeoutSeconds":10}
            """#
            try legacy.write(to: url, atomically: true, encoding: .utf8)
            let migrated = store.load()
            try expectEqual(migrated.whisperModelId, "large-v3-turbo")  // 새 필드 기본값
            try expectEqual(migrated.activeModeId, "email")             // 진짜 디코딩 증명
        }
    }

    await t.test("ConfigStore: vocabulary/replacements/pasteMethod 왕복") {
        try await withTempDir { dir in
            let url = dir.appendingPathComponent("config.json")
            let store = ConfigStore(url: url)

            var config = store.load()
            config.vocabulary = "Wisp, GRDB, SwiftUI"
            config.speechPeakThreshold = 0.04
            config.replacements = [
                ReplacementRule(from: "깃헙", to: "GitHub"),
                ReplacementRule(from: "->", to: "→", caseSensitive: true),
            ]
            config.pasteMethod = .keystroke
            try store.save(config)

            let loaded = store.load()
            try expectEqual(loaded.vocabulary, "Wisp, GRDB, SwiftUI")
            try expectEqual(loaded.speechPeakThreshold, 0.04)
            try expectEqual(loaded.replacements.count, 2)
            try expectEqual(loaded.replacements.first?.from, "깃헙")
            try expectEqual(loaded.replacements.first?.to, "GitHub")
            try expectEqual(loaded.replacements.last?.caseSensitive, true)
            try expectEqual(loaded.pasteMethod, .keystroke)
            try expectEqual(loaded, config)   // id 포함 완전 왕복
        }
    }
}
