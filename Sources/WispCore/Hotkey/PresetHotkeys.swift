/// 프리셋(모드) 빠른 선택 핫키 정의.
/// 받아쓰기 중(PTT 보조키를 쥔 채) 숫자키 1…9를 누르면 모드 리스트의 그 슬롯
/// 모드를 "이번 받아쓰기의 후처리 프롬프트"로 고른다. 슬롯 i(0-based)는 숫자 i+1.
enum PresetHotkeys {
    /// 지원 슬롯 수(숫자 1~9 다음 0 = 총 10개).
    static let maxSlots = 10

    /// 슬롯 순서대로의 숫자키 Carbon 가상 키코드. 1~9 다음 10번째 슬롯은 0.
    /// (숫자 행은 6/7 경계에서 코드가 뒤집혀 있어 1→18 … 9→25, 0→29.)
    private static let keyCodes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]

    /// 키코드 → 슬롯(0-based). 숫자키가 아니면 nil.
    static func slot(forKeyCode keyCode: UInt32) -> Int? {
        keyCodes.firstIndex(of: keyCode)
    }

    /// 슬롯에 대응하는 표시 숫자(슬롯0→1 … 슬롯8→9, 슬롯9→0).
    static func digit(slot: Int) -> Int {
        (slot + 1) % 10
    }
}
