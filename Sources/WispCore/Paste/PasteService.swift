import AppKit
import ApplicationServices

/// 자동 붙여넣기 방식.
public enum PasteMethod: String, Codable, CaseIterable {
    /// 클립보드에 쓰고 ⌘V를 주입(기본, 빠름).
    case clipboard
    /// 텍스트를 문자별 키 입력으로 타이핑. ⌘V가 막히는 보안 입력 필드·일부
    /// Electron/웹뷰 앱에서 동작한다(느리지만 호환성 높음).
    case keystroke

    public var displayName: String {
        switch self {
        case .clipboard: return "붙여넣기 (⌘V)"
        case .keystroke: return "키 입력 시뮬레이션"
        }
    }
}

final class PasteService: Pasting {
    private let sendKeystroke: () -> Void
    private let typeText: (String) -> Void
    private let isTrusted: () -> Bool
    private let restoreDelay: TimeInterval
    /// 설정에서 즉시 바꿀 수 있도록 가변. apply(...)로 갱신.
    private var autoPaste: Bool
    private var restoreClipboard: Bool
    private var pasteMethod: PasteMethod
    @MainActor private var restoreGeneration = 0

    /// restoreClipboard 기본값 false: 결과를 클립보드에 남긴다.
    /// ⌘V 주입이 포커스 없는 곳에 떨어져도 사용자가 수동 ⌘V로 복구할 수 있다 —
    /// 복원해버리면 그 경우 전사 텍스트가 어디에도 남지 않고 증발한다.
    init(sendKeystroke: (() -> Void)? = nil,
         typeText: ((String) -> Void)? = nil,
         isTrusted: (() -> Bool)? = nil,
         restoreDelay: TimeInterval = 0.3,
         autoPaste: Bool = true,
         restoreClipboard: Bool = false,
         pasteMethod: PasteMethod = .clipboard) {
        self.sendKeystroke = sendKeystroke ?? Self.postCmdV
        self.typeText = typeText ?? Self.postUnicode
        self.isTrusted = isTrusted ?? { AXIsProcessTrusted() }
        self.restoreDelay = restoreDelay
        self.autoPaste = autoPaste
        self.restoreClipboard = restoreClipboard
        self.pasteMethod = pasteMethod
    }

    /// 설정 변경 즉시 적용 (재시작 불필요).
    func apply(autoPaste: Bool, restoreClipboard: Bool, pasteMethod: PasteMethod) {
        self.autoPaste = autoPaste
        self.restoreClipboard = restoreClipboard
        self.pasteMethod = pasteMethod
    }

    @discardableResult
    @MainActor func paste(_ text: String) -> PasteResult {
        let pasteboard = NSPasteboard.general
        // 복원용으로 클립보드 전체(모든 타입)를 떠둔다 — string만 백업하면
        // 이미지·RTF 등 다른 타입이 클립보드 기록으로 덮여 사라진다.
        let backup = restoreClipboard ? Self.snapshot(pasteboard) : nil
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // 자동 붙여넣기 꺼짐: 클립보드에만 남긴다.
        guard autoPaste else { return .clipboardOnly }

        // CGEventPost(⌘V·키입력)는 손쉬운 사용 권한이 있어야 시스템에 전달된다.
        // 권한이 없으면 조용히 버려져 클립보드에만 남는다 — 이때는 사용자에게 알린다.
        guard isTrusted() else {
            NSLog("WISP_PASTE: 손쉬운 사용 권한 없음 — 자동 입력 불가, 클립보드만")
            return .needsAccessibility
        }

        // 포커스 대상을 미리 검사하지 않는다 — 시스템 와이드 AX focused-element 조회는
        // 웹뷰/Electron 등에서 텍스트 필드가 포커스돼 있어도 nil을 반환해 붙여넣기를
        // 과도하게 막았다. 그냥 보내고, 떨어질 곳이 없으면 클립보드(위)가 폴백.
        switch pasteMethod {
        case .clipboard:
            sendKeystroke()
        case .keystroke:
            // 키 입력은 클립보드를 거치지 않고 직접 타이핑하므로, 복원할 게 있으면
            // 굳이 기다릴 필요 없이 바로 되돌릴 수 있지만 타이밍 일관성을 위해 동일 경로.
            typeText(text)
        }

        if restoreClipboard {
            restoreGeneration += 1
            let gen = restoreGeneration
            let delay = restoreDelay
            Task {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await MainActor.run {
                    guard self.restoreGeneration == gen else { return }
                    Self.restore(pasteboard, from: backup)
                }
            }
        }
        return .pasted
    }

    // MARK: - 클립보드 스냅샷/복원 (다중 타입)

    /// 현재 클립보드의 모든 아이템·타입을 독립 복사한다. NSPasteboardItem은
    /// clearContents 후 무효화되므로 data를 즉시 읽어 새 아이템으로 복제해야 한다.
    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        guard let items = pb.pasteboardItems else { return [] }
        return items.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func restore(_ pb: NSPasteboard, from backup: [NSPasteboardItem]?) {
        guard let backup, !backup.isEmpty else { return }
        pb.clearContents()
        pb.writeObjects(backup)
    }

    // MARK: - 입력 주입

    static func postCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)   // 9 = V
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    /// Return 키 전송(트랙패드 톡 1번 = 전송). postCmdV와 동일하게 손쉬운 사용
    /// 권한이 있어야 시스템에 전달되며, 없으면 조용히 버려진다.
    ///
    /// HID tap(하드웨어 레벨)으로 쏜다: raw-mode로 stdin을 읽는 터미널 TUI(Claude Code
    /// 입력 등)는 세션 레벨 합성 키를 흘리는 경우가 있는데, HID 레벨은 실제 키처럼 입력
    /// 스택 전체를 거쳐 전달돼 더 안정적이다(클릭이 끼면 동작하던 것과 같은 맥락).
    /// flags를 비워 순수 Return으로 보낸다 — ⇧/⌥+Return은 TUI에서 제출이 아니라 줄바꿈이다.
    static func postReturn() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)   // 36 = Return
        let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
        down?.flags = []
        up?.flags = []
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Backspace를 count번 전송(트랙패드 톡 2번 = 방금 받아쓴 글자 수만큼 삭제).
    /// ⌘Z(앱 네이티브 undo)와 달리 터미널·검색창 등 undo 스택이 없는 입력에서도
    /// 동작한다 — 커서 앞 글자를 직접 지우기 때문. 받아쓰기 직후(커서 이동 전) 전제.
    /// Return과 같은 이유로 HID tap + 빈 flags를 쓴다.
    static func postBackspaces(_ count: Int) {
        guard count > 0 else { return }
        let s = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<count {
            let down = CGEvent(keyboardEventSource: s, virtualKey: 51, keyDown: true)   // 51 = Delete(Backspace)
            let up = CGEvent(keyboardEventSource: s, virtualKey: 51, keyDown: false)
            down?.flags = []
            up?.flags = []
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    /// 텍스트를 유니코드 문자열로 직접 타이핑한다(키코드가 아니라 문자 삽입이라
    /// 한글·이모지도 그대로 들어간다). 이벤트 하나에 너무 긴 문자열을 실으면 일부
    /// 앱이 잘라먹어 작은 청크로 나눠 보낸다.
    static func postUnicode(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        let chunkSize = 20
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + chunkSize, units.count)])
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
                else { continue }
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event.post(tap: .cgSessionEventTap)
            }
            i += chunkSize
        }
    }
}
