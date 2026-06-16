import Foundation
@testable import WispCore

@MainActor
func scaffoldTests(_ t: TestRunner) async {
    await t.test("Scaffold: AppContainer 초기화") {
        let container = AppContainer()
        try expect(type(of: container) == AppContainer.self)
    }
}
