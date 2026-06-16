import AppKit

/// 단독 보조키(예: ⌃ Control) 전역 핫키. Carbon RegisterEventHotKey는 보조키
/// 단독 등록을 지원하지 않으므로 NSEvent 전역 모니터(flagsChanged/keyDown)로
/// 구현한다. 손쉬운 사용 권한이 없으면 전역 모니터에 이벤트가 오지 않는다.
///
/// 동작: 대상 보조키가 단독으로 눌리면 onDown, 떼면 onUp. 유지 중 다른 키나
/// 보조키가 개입하면(⌃C 등 조합 입력) onInterrupt — 상태 기계가 이번 누름을
/// 단축키가 아닌 것으로 처리한다. 다른 보조키가 이미 눌린 채 대상 키가 내려오면
/// 처음부터 조합으로 보고 아무 이벤트도 보내지 않는다.
final class ModifierHotkey {
    var onDown: () -> Void = {}
    var onUp: () -> Void = {}
    var onInterrupt: () -> Void = {}
    /// 보조키 유지 중 숫자키(1~9) 입력 — 이번 받아쓰기에 적용할 프리셋 슬롯 선택.
    /// 녹음은 유지된다(interrupt와 달리 취소하지 않음). slot은 0-based.
    var onPresetSelect: (Int) -> Void = { _ in }
    /// 프리셋 선택 기능 활성 여부(설정). 꺼져 있으면 숫자키도 일반 개입으로 처리.
    var isPresetEnabled: () -> Bool = { false }

    private let flag: NSEvent.ModifierFlags
    private var monitors: [Any] = []
    private var held = false
    private var sentDown = false

    init(flag: NSEvent.ModifierFlags) {
        self.flag = flag
    }

    static func flag(named name: String) -> NSEvent.ModifierFlags? {
        switch name {
        case "control": return .control
        case "option": return .option
        case "command": return .command
        case "shift": return .shift
        default: return nil
        }
    }

    func register() {
        unregister()
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.handleFlagsChanged(event)
        }) { monitors.append(m) }
        // 보조키 유지 중 일반 키 입력(⌃C 등) 감지. 단, 프리셋이 켜져 있고 숫자키(1~9)면
        // 취소가 아니라 프리셋 선택으로 처리해 녹음을 유지한다.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, self.held, self.sentDown else { return }
            if self.isPresetEnabled(), let slot = PresetHotkeys.slot(forKeyCode: UInt32(event.keyCode)) {
                self.onPresetSelect(slot)
            } else {
                self.onInterrupt()
            }
        }) { monitors.append(m) }
    }

    func unregister() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        held = false
        sentDown = false
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection([.control, .option, .command, .shift])
        let hasFlag = mods.contains(flag)
        var others = mods
        others.subtract(flag)

        if hasFlag && !held {
            held = true
            sentDown = others.isEmpty  // 다른 보조키가 이미 눌려 있으면 조합 — 무시
            if sentDown { onDown() }
        } else if hasFlag && held {
            if sentDown && !others.isEmpty { onInterrupt() }  // 유지 중 보조키 추가
        } else if !hasFlag && held {
            held = false
            if sentDown { onUp() }
            sentDown = false
        }
    }

    deinit {
        // NSEvent.removeMonitor는 메인 스레드 권장 — 앱 수명 동안 유지되는 객체라
        // 실질적으로는 호출되지 않지만, 누수 경고 방지를 위해 정리한다.
        for m in monitors { NSEvent.removeMonitor(m) }
    }
}
