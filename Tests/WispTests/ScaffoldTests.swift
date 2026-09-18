import Foundation
@testable import WispCore

@MainActor
func scaffoldTests(_ t: TestRunner) async {
    await t.test("Scaffold: AppContainer 초기화") {
        let container = AppContainer()
        try expect(type(of: container) == AppContainer.self)
    }

    await t.test("Scaffold: 키보드 단축키를 끄면 활성 트리거 표시에서 제외") {
        let container = AppContainer()
        try expectEqual(container.activationLabel, "⌃ Control 받아쓰기")

        container.config.keyboardHotkeyEnabled = false
        try expectEqual(container.activationLabel, "활성 트리거 없음")
        try expectEqual(container.bareModifierSymbol, String?.none)

        container.config.trackpadFingerCount = 4
        try expectEqual(container.activationLabel, "트랙패드 4손가락")
    }
}
