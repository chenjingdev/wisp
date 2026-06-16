import Carbon.HIToolbox

/// 전역 핫키 등록. pressed/released 이벤트를 콜백으로 전달.
final class CarbonHotkey {
    var onDown: () -> Void = {}
    var onUp: () -> Void = {}

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var retainedSelf: Unmanaged<CarbonHotkey>?

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister()
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let retained = Unmanaged.passRetained(self)
        retainedSelf = retained
        let selfPtr = retained.toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            let hotkey = Unmanaged<CarbonHotkey>.fromOpaque(userData).takeUnretainedValue()
            switch GetEventKind(event) {
            case UInt32(kEventHotKeyPressed): hotkey.onDown()
            case UInt32(kEventHotKeyReleased): hotkey.onUp()
            default: break
            }
            return noErr
        }, eventTypes.count, &eventTypes, selfPtr, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x57495350), id: 1)  // 'WISP'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
        return status == noErr
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        if let handlerRef { RemoveEventHandler(handlerRef); self.handlerRef = nil }
        retainedSelf?.release(); retainedSelf = nil
    }

    deinit { unregister() }
}
