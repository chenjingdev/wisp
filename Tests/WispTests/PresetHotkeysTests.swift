import Foundation
@testable import WispCore

@MainActor func presetHotkeysTests(_ t: TestRunner) async {
    await t.test("PresetHotkeys: 키코드 → 슬롯 매핑 (1~9 다음 0 = 10슬롯)") {
        try expectEqual(PresetHotkeys.maxSlots, 10)
        // 숫자 행 대표값: 1→슬롯0, 5→슬롯4, 9→슬롯8, 0→슬롯9
        try expectEqual(PresetHotkeys.slot(forKeyCode: 18), Int?.some(0))
        try expectEqual(PresetHotkeys.slot(forKeyCode: 23), Int?.some(4))
        try expectEqual(PresetHotkeys.slot(forKeyCode: 25), Int?.some(8))
        try expectEqual(PresetHotkeys.slot(forKeyCode: 29), Int?.some(9))   // 0
        // 숫자키가 아니면 nil (Esc=53, 임의값)
        try expectEqual(PresetHotkeys.slot(forKeyCode: 53), Int?.none)
        try expectEqual(PresetHotkeys.slot(forKeyCode: 99), Int?.none)
    }

    await t.test("PresetHotkeys: 슬롯 표시 숫자 (마지막 슬롯은 0)") {
        try expectEqual(PresetHotkeys.digit(slot: 0), 1)
        try expectEqual(PresetHotkeys.digit(slot: 8), 9)
        try expectEqual(PresetHotkeys.digit(slot: 9), 0)
    }
}
