import AppKit

/// 키 레코더의 이벤트 → 단축키 설정 변환. NSEvent 원시 값만 받는 순수 로직
/// (모니터 설치는 UI가 담당) — 자동 테스트 대상.
struct HotkeyCapture {
    enum Outcome: Equatable {
        case combo(keyCode: UInt32, carbonModifiers: UInt32)
        case bareModifier(String)   // "control" | "option" | "command" | "shift" | "function"
        case cancelled              // Esc
        case pending                // 보조키 누름 진행 중 — 계속 대기
        case ignored                // 지원하지 않는 입력 (보조키 없는 일반키 등)
    }

    private var lastModifiers: NSEvent.ModifierFlags = []

    mutating func handleKeyDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Outcome {
        if keyCode == 53 { return .cancelled }  // Esc
        let carbon = Self.carbonModifiers(from: flags)
        lastModifiers = []
        guard carbon != 0 else { return .ignored }  // 무보조키 단축키는 위험 — 금지
        return .combo(keyCode: UInt32(keyCode), carbonModifiers: carbon)
    }

    mutating func handleFlagsChanged(flags: NSEvent.ModifierFlags) -> Outcome {
        let mods = flags.intersection([.control, .option, .command, .shift, .function])
        defer { lastModifiers = mods }
        // 모두 떼어졌고 직전에 정확히 하나만 눌려 있었다면 → 단독 보조키 확정
        if mods.isEmpty, let name = Self.singleName(of: lastModifiers) {
            return .bareModifier(name)
        }
        return .pending
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= 0x100 }   // cmdKey
        if flags.contains(.shift)   { carbon |= 0x200 }   // shiftKey
        if flags.contains(.option)  { carbon |= 0x800 }   // optionKey
        if flags.contains(.control) { carbon |= 0x1000 }  // controlKey
        return carbon
    }

    static func singleName(of flags: NSEvent.ModifierFlags) -> String? {
        switch flags.intersection([.control, .option, .command, .shift, .function]) {
        case [.control]: return "control"
        case [.option]: return "option"
        case [.command]: return "command"
        case [.shift]: return "shift"
        case [.function]: return "function"
        default: return nil
        }
    }

    /// 표시용 라벨: "⌃⌥⇧⌘" + 키 이름. AppContainer.hotkeyLabel에서 사용.
    static func label(keyCode: UInt32, carbonModifiers: UInt32) -> String {
        var symbols = ""
        if carbonModifiers & 0x1000 != 0 { symbols += "⌃" }
        if carbonModifiers & 0x800 != 0 { symbols += "⌥" }
        if carbonModifiers & 0x200 != 0 { symbols += "⇧" }
        if carbonModifiers & 0x100 != 0 { symbols += "⌘" }
        return symbols + (keyNames[keyCode] ?? "키\(keyCode)")
    }

    private static let keyNames: [UInt32: String] = [
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Esc",
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P",
        12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
        16: "Y", 6: "Z",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7",
        28: "8", 25: "9", 29: "0",
    ]
}
