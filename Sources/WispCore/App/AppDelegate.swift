import AppKit
import ApplicationServices
import Combine
import SwiftUI

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public let container = AppContainer()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // 죽은 자식 프로세스 stdin에 write하면 SIGPIPE로 앱 전체가 종료(exit 141)되는 것을 방지.
        // 무시하면 write 실패가 잡을 수 있는 에러/무시 가능한 드롭으로 표면화된다.
        signal(SIGPIPE, SIG_IGN)
        NSApp.setActivationPolicy(.accessory)
        Task { await container.bootstrap() }
    }

    // 메뉴바 전용 앱이라 창이 없어 "실행해도 아무 반응이 없는" 것처럼 보인다.
    // 이미 실행 중일 때 다시 열면(Finder 더블클릭, open -a) HUD로 생존 신호를 보낸다.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        container.hud.flash("Wisp 실행 중 — \(container.hotkeyLabel) 받아쓰기")
        return false
    }

    // 녹음 중 종료 시 일시정지한 미디어·낮춘 볼륨을 원복한다(시스템 전역 상태 잔존 방지).
    public func applicationWillTerminate(_ notification: Notification) {
        container.cleanupOnQuit()
    }
}

@MainActor
public final class AppContainer: ObservableObject {
    @Published public private(set) var statusText = "초기화 중…"
    @Published public var modes: [Mode] = []
    @Published public var activeModeId = "dictation"

    let hud = HUDController()
    private(set) var controller: RecordingController?
    private(set) var history: HistoryStoring?
    private var configStore = ConfigStore()
    @Published var config = WispConfig()
    private let modeStore = ModeStore()
    private let permissions = PermissionsService()
    private lazy var onboarding = OnboardingController(permissions: permissions)
    /// 모델 카탈로그 디스크 상태/다운로드 — 설정 패널·첫 실행 창이 관찰한다.
    let modelManager = ModelManager()
    /// 첫 실행/모델 부재 시 모델 선택·다운로드 창.
    private lazy var modelSetup = ModelSetupController(container: self)
    private let hotkey = CarbonHotkey()
    private var modifierHotkey: ModifierHotkey?
    private var multitouchHotkey: MultitouchHotkey?
    /// 트랙패드 탭/홀드 해석기 — 콜백이 죽지 않도록 강참조로 보관한다.
    private var tapHoldRecognizer: TapHoldRecognizer?
    private let escMonitor = EscMonitor()
    /// 설정 변경 즉시 적용을 위해 인스턴스 보관 (붙여넣기 동작 갱신).
    private var pasteService: PasteService?
    /// 종료 시 미디어/볼륨 복원을 위해 보관.
    private var effects: RecordingEffectsService?
    private var cancellables: Set<AnyCancellable> = []

    /// 현재 설정된 단축키의 표시용 라벨
    var hotkeyLabel: String {
        if let name = config.hotkeyBareModifier, ModifierHotkey.flag(named: name) != nil {
            switch name {
            case "control": return "⌃ Control"
            case "option": return "⌥ Option"
            case "command": return "⌘ Command"
            case "shift": return "⇧ Shift"
            default: return name
            }
        }
        return HotkeyCapture.label(keyCode: config.hotkeyKeyCode, carbonModifiers: config.hotkeyModifiers)
    }

    /// 단독 보조키 PTT의 기호(⌃/⌥/⌘/⇧). 콤보 단축키면 nil — 프리셋 숫자 선택은
    /// 단독 보조키를 쥔 채 누르는 방식이라 보조키가 있을 때만 의미가 있다.
    var bareModifierSymbol: String? {
        switch config.hotkeyBareModifier {
        case "control": return "⌃"
        case "option": return "⌥"
        case "command": return "⌘"
        case "shift": return "⇧"
        default: return nil
        }
    }

    /// 현재 활성 모드의 표시 이름.
    var activeModeName: String {
        modes.first { $0.id == activeModeId }?.name ?? activeModeId
    }

    public init() {}

    public func bootstrap() async {
        do {
            try AppPaths.ensureDirectories()
            // 구버전이 디스크에 남긴 녹음 wav 폴더를 1회 정리(이제 wav를 저장하지 않음).
            try? FileManager.default.removeItem(at: AppPaths.recordings)
            config = configStore.load()
            try modeStore.seedDefaultsIfNeeded()
            modes = try modeStore.loadAll()
            activeModeId = config.activeModeId

            // 권한 — 빠진 게 있으면 온보딩 창으로 안내(마이크·손쉬운 사용).
            // 시스템 설정에서 켜면 창이 실시간으로 ✓ 반영한다.
            onboarding.showIfNeeded()

            await ensureModelThenStart()
        } catch {
            statusText = "초기화 실패: \(error.localizedDescription)"
            hud.flash("Wisp 초기화 실패: \(error.localizedDescription)", seconds: 6)
        }
    }

    /// 현재 활성 whisper 모델(알 수 없는 id면 기본 모델로 폴백).
    var activeModel: WhisperModel { ModelCatalog.modelOrDefault(id: config.whisperModelId) }

    /// 활성 모델 파일이 있으면 엔진을 켜고, 없으면 첫 실행 모델 셋업 창으로 안내한다.
    /// 더는 조용히 turbo를 받지 않는다 — 사용자가 모델을 고르고 다운로드 진행률을 본다.
    private func ensureModelThenStart() async {
        let url = modelManager.fileURL(for: activeModel)
        if FileManager.default.fileExists(atPath: url.path) {
            await startEngine(modelURL: url)
        } else {
            statusText = "받아쓰기 모델을 다운로드하세요"
            hud.flash("Wisp: 받아쓰기 모델을 먼저 다운로드하세요", seconds: 5)
            showModelSetup()
        }
    }

    /// 모델 셋업 창을 띄운다. 활성 모델 다운로드가 끝나고 "시작하기"를 누르면 엔진을 켠다.
    private func showModelSetup() {
        modelSetup.show { [weak self] in
            guard let self else { return }
            Task { await self.startEngine(modelURL: self.modelManager.fileURL(for: self.activeModel)) }
        }
    }

    /// 전사 엔진 + 받아쓰기 파이프라인을 구성한다(모델 파일이 준비된 뒤 1회).
    /// 모델 손상이면 파일을 지우고 다시 셋업 창으로 안내한다.
    private func startEngine(modelURL: URL) async {
        // 이미 켜져 있으면(재진입) 런타임 전환 경로로 처리.
        guard controller == nil else {
            switchTranscriptionEngine(to: activeModel)
            return
        }
        do {
            let transcription = TranscriptionService(modelURL: modelURL, vadModelURL: AppPaths.vadModelURL)
            statusText = "모델 로드 중…"
            do {
                try await transcription.warmUp()
            } catch WispError.modelLoadFailed {
                // 모델 파일 손상 추정 — 삭제 후 다시 다운로드하도록 셋업 창으로 안내.
                try? FileManager.default.removeItem(at: modelURL)
                statusText = "모델 손상 — 다시 다운로드하세요"
                hud.flash("Wisp: 모델 파일이 손상됐습니다 — 다시 다운로드하세요", seconds: 6)
                showModelSetup()
                return
            }

            let history = try HistoryStore(path: AppPaths.databaseURL.path)
            self.history = history
            runAutoCleanup()

            let pasteService = PasteService(
                autoPaste: config.autoPaste,
                restoreClipboard: config.restoreClipboard,
                pasteMethod: config.pasteMethod
            )
            self.pasteService = pasteService
            let effects = RecordingEffectsService(
                media: MediaController(),
                output: AudioOutputController(),
                sound: SoundFeedback(),
                soundEnabled: { [weak self] in self?.config.soundFeedback ?? true }
            )
            self.effects = effects
            let controller = RecordingController(
                audio: AudioService(),
                transcription: transcription,
                postProcess: makePostProcessor(),
                paste: pasteService,
                history: history,
                modeProvider: { [weak self] in
                    // 종료 시점에 평가됨 — 녹음 중 숫자로 활성 모드를 바꿨으면 그게 반영된다.
                    guard let self,
                          let mode = try? self.modeStore.mode(id: self.activeModeId)
                    else { return Mode.defaults[0] }
                    return mode
                },
                effects: effects,
                vocabulary: { [weak self] in self?.config.vocabulary ?? "" },
                replace: { [weak self] text in
                    TextReplacer.apply(text, rules: self?.config.replacements ?? [])
                },
                captureContext: { [weak self] in self?.captureDictationContext() ?? DictationContext() }
            )
            self.controller = controller
            bindHUD(controller)
            registerHotkey(controller)
            if config.hotkeyBareModifier != nil, !permissions.axTrusted(prompt: false) {
                // 단독 보조키는 NSEvent 전역 모니터 기반 — 손쉬운 사용 권한 필수
                statusText = "손쉬운 사용 권한 필요 (단축키 비활성)"
                hud.flash("Wisp: 손쉬운 사용 권한을 허용해야 \(hotkeyLabel) 단축키가 동작합니다", seconds: 6)
            } else {
                statusText = "대기 중 (\(hotkeyLabel))"
                hud.flash("Wisp 준비 완료 — \(hotkeyLabel) 받아쓰기")
            }
        } catch {
            statusText = "초기화 실패: \(error.localizedDescription)"
            hud.flash("Wisp 초기화 실패: \(error.localizedDescription)", seconds: 6)
        }
    }

    /// 설정에서 모델을 활성으로 지정한다. 엔진이 켜져 있고 모델이 받아져 있으면 런타임 전환.
    func selectModel(_ id: String) {
        guard let model = ModelCatalog.model(id: id) else { return }
        config.whisperModelId = id
        saveConfig()
        if controller != nil, modelManager.isDownloaded(model) {
            switchTranscriptionEngine(to: model)
        }
    }

    /// 활성 모델을 새 경로로 재생성하고 warmUp 후 컨트롤러에 교체한다(백그라운드 —
    /// 받아쓰기 핫패스를 막지 않는다). rebuildPostProcessor와 같은 런타임 재구성 패턴.
    func switchTranscriptionEngine(to model: WhisperModel) {
        let url = modelManager.fileURL(for: model)
        statusText = "모델 전환 중… (\(model.displayName))"
        Task { @MainActor in
            let service = TranscriptionService(modelURL: url, vadModelURL: AppPaths.vadModelURL)
            do {
                try await service.warmUp()
                controller?.replaceTranscription(service)
                statusText = "대기 중 (\(hotkeyLabel)) — \(model.displayName)"
            } catch {
                statusText = "모델 전환 실패: \(error.localizedDescription)"
                hud.flash("Wisp: 모델 전환 실패 — \(error.localizedDescription)", seconds: 5)
            }
        }
    }

    /// Phase 2: codex spark 후처리. codex 바이너리가 없으면 Passthrough로 강등.
    /// 설정 경로가 없으면 PATH·흔한 위치에서 자동 탐지한다(머신마다 설치 경로가 달라
    /// 다른 컴퓨터에서 클론해도 바로 동작하도록). 탐지 결과는 설정에 저장한다.
    func makePostProcessor() -> PostProcessing {
        guard let codexPath = CodexLocator.resolve(configured: config.codexBinaryPath) else {
            NSLog("Wisp: codex 바이너리 없음(\(config.codexBinaryPath)) — LLM 후처리 비활성")
            return PassthroughPostProcessor()
        }
        if codexPath != config.codexBinaryPath {
            NSLog("Wisp: codex 자동 탐지 — \(codexPath)")
            config.codexBinaryPath = codexPath
            try? configStore.save(config)
        }
        return PostProcessService(
            makeClient: {
                CodexAppServerClient(
                    executableURL: URL(fileURLWithPath: codexPath),
                    // 받아쓰기 후처리에 MCP 서버·notify 훅은 불필요 + 지연/부작용 유발 — 프로세스 단위로 비활성
                    arguments: ["app-server", "-c", "mcp_servers={}", "-c", "notify=[]"]
                )
            },
            model: config.codexModel,
            timeout: config.llmTimeoutSeconds,
            execFallback: PostProcessService.makeRealExecFallback(
                codexPath: codexPath, model: config.codexModel
            )
        )
    }

    public func setActiveMode(_ id: String) {
        activeModeId = id
        config.activeModeId = id
        try? configStore.save(config)
    }

    /// 설정 저장 (패널들이 config 수정 후 호출)
    func saveConfig() {
        try? configStore.save(config)
    }

    /// 설정 패널용 바인딩 팩토리 — 값 쓰기 → 저장 → 도메인별 즉시-적용을 한 곳에서
    /// 보장한다. 패널마다 같은 보일러플레이트를 손으로 반복하던 것을 대체.
    func binding<V>(_ keyPath: WritableKeyPath<WispConfig, V>,
                    apply: @escaping @MainActor () -> Void = {}) -> Binding<V> {
        Binding(
            get: { self.config[keyPath: keyPath] },
            set: { self.config[keyPath: keyPath] = $0; self.saveConfig(); apply() }
        )
    }

    /// 기록 1건 삭제.
    func deleteRecord(id: String) {
        try? history?.delete(id: id)
    }

    /// 단축키/PTT 임계값 변경 즉시 적용 — 기존 등록 해제 후 재등록.
    /// 등록 실패(다른 앱과 Carbon 충돌 등) 시 상태 텍스트로 경고하고 롤백하지
    /// 않는다 (스펙 §6 — 사용자가 다른 키를 다시 고르면 됨).
    func reregisterHotkey() {
        guard let controller else { return }
        hotkey.unregister()
        modifierHotkey?.unregister()
        modifierHotkey = nil
        multitouchHotkey?.unregister()
        multitouchHotkey = nil
        tapHoldRecognizer?.reset()
        tapHoldRecognizer = nil
        let ok = registerHotkey(controller)
        statusText = ok ? "대기 중 (\(hotkeyLabel))" : "단축키 등록 실패 — 다른 키를 선택하세요"
    }

    /// 받아쓰기 중 숫자키로 프리셋 슬롯을 골랐을 때 — 활성 모드를 그 모드로 바꾼다.
    /// 녹음은 유지되며, 손을 떼는 종료 시점에 modeProvider가 새 활성 모드를 읽어
    /// 이번 받아쓰기에 적용한다. 활성 모드 자체가 바뀌므로 다음 받아쓰기에도 유지된다.
    private func activatePreset(slot: Int) {
        guard modes.indices.contains(slot) else { return }
        let mode = modes[slot]
        setActiveMode(mode.id)
        hud.setModeLabel(mode.name)
    }

    /// codex 설정 변경 즉시 적용 (whisper 모델은 유지)
    func rebuildPostProcessor() {
        controller?.replacePostProcessor(makePostProcessor())
    }

    /// 붙여넣기 설정(자동 붙여넣기·클립보드 복원·출력 방식) 변경 즉시 적용.
    func applyPasteSettings() {
        pasteService?.apply(autoPaste: config.autoPaste,
                            restoreClipboard: config.restoreClipboard,
                            pasteMethod: config.pasteMethod)
    }

    /// 앱 종료 시 호출 — 녹음 중이었다면 일시정지한 미디어/낮춘 볼륨을 복원.
    func cleanupOnQuit() {
        effects?.onRecordingEnd()
    }

    /// 권한 온보딩 창을 연다 (메뉴에서 호출).
    func openOnboarding() {
        onboarding.show()
    }

    func reloadModes() {
        modes = (try? modeStore.loadAll()) ?? modes
    }

    func createMode() -> Mode? {
        guard modes.count < PresetHotkeys.maxSlots,   // 최대 10개(0~9)
              let mode = try? modeStore.create() else { return nil }
        reloadModes()
        return mode
    }

    func saveMode(_ mode: Mode) {
        try? modeStore.save(mode)
        reloadModes()
    }

    func deleteMode(id: String) {
        try? modeStore.delete(id: id)
        reloadModes()
        // 활성 모드를 지웠으면 남은 첫 모드로 전환(고정 "dictation" 가정 없이).
        if activeModeId == id { setActiveMode(modes.first?.id ?? "dictation") }
    }

    /// autoCleanupDays 기준으로 오래된 기록 삭제. 시작 시와 설정 변경 시 호출.
    func runAutoCleanup() {
        guard let days = config.autoCleanupDays, days > 0, let history else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        try? history.purge(olderThan: cutoff)
    }

    /// 녹음 시작 시 주변 컨텍스트를 캡처한다. 어떤 모드도 컨텍스트를 쓰지 않으면
    /// 접근성/클립보드 조회 자체를 건너뛴다(기본 상태에선 비용 0).
    private func captureDictationContext() -> DictationContext {
        let wantsSelection = modes.contains { $0.useSelectedText }
        let wantsClipboard = modes.contains { $0.useClipboardContext }
        return DictationContext(
            selectedText: wantsSelection ? Self.focusedSelectedText() : nil,
            clipboardText: wantsClipboard ? NSPasteboard.general.string(forType: .string) : nil
        )
    }

    /// 활성 앱에서 현재 선택(하이라이트)된 텍스트를 접근성 API로 읽는다. ⌘C를
    /// 흉내내지 않아 클립보드를 건드리지 않는다. 권한이 없거나 미지원 앱이면 nil.
    private static func focusedSelectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focusedRef = focused
        else { return nil }
        let element = focusedRef as! AXUIElement
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty
        else { return nil }
        return text
    }

    public func copyLastResult() {
        guard let record = try? history?.fetchLatest(),
              let text = record.llmOutput ?? record.transcript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func bindHUD(_ controller: RecordingController) {
        controller.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.hud.update(state: state, notice: self?.controller?.notice)
            }
            .store(in: &cancellables)
        controller.$inputLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in self?.hud.update(level: level) }
            .store(in: &cancellables)
    }

    @discardableResult
    private func registerHotkey(_ controller: RecordingController) -> Bool {
        let ok = registerKeyboardHotkey(controller)
        registerTrackpadHotkey(controller)   // 트랙패드 트리거(설정 시)와 병행
        return ok
    }

    /// 핫키 액션(누름/뗌/취소)을 녹음 제어로 잇는 공통 핸들러. 키보드·트랙패드 트리거가
    /// 각자의 상태 기계를 갖고 같은 로직을 공유한다. reset은 Esc 취소 시 해당 기계 초기화.
    /// Hotkey events arrive on the main thread; MainActor.assumeIsolated로 Task 생성
    /// 없이 호출해 재진입/순서 문제를 피한다.
    private func makeHotkeyApply(_ controller: RecordingController,
                                 reset: @escaping () -> Void) -> (HotkeyStateMachine.Action) -> Void {
        { [weak self, weak controller] action in
            MainActor.assumeIsolated {
                guard let self, let controller else { return }
                switch action {
                case .startRecording: self.beginRecording(controller, reset: reset)
                case .stopRecording: self.endRecording(controller)
                case .cancelRecording: controller.cancel(); self.escMonitor.stop()
                case .none: break
                }
            }
        }
    }

    /// 녹음 시작 + 활성 모드 라벨 + Esc 취소 모니터. 키보드 핫키와 트랙패드 hold가 공유.
    private func beginRecording(_ controller: RecordingController, reset: @escaping () -> Void) {
        controller.startRecording()
        hud.setModeLabel(activeModeName)
        escMonitor.start { [weak controller] in
            Task { @MainActor in
                controller?.cancel()
                reset()
            }
        }
    }

    /// 녹음 종료 → 처리 시작 + Esc 모니터 정리. 키보드·트랙패드 공유.
    private func endRecording(_ controller: RecordingController) {
        controller.stopAndProcess()
        escMonitor.stop()
    }

    /// 트랙패드 5손가락이 완전히 떨어진 뒤(currentCount==0) 합성 키를 보낸다. 잔여
    /// 접촉 중엔 modifier가 누락되거나(⌘Z→z) 키가 씹히므로, 0을 짧게 폴링한 뒤 실행한다.
    /// 최대 ~0.4초까지 기다리고, 그래도 안 떨어지면 그냥 시도한다.
    private func sendKeyAfterRelease(_ send: @escaping () -> Void, attemptsLeft: Int = 12) {
        if (multitouchHotkey?.currentCount ?? 0) == 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: send)  // 0 직후 살짝 안정화
        } else if attemptsLeft > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                self?.sendKeyAfterRelease(send, attemptsLeft: attemptsLeft - 1)
            }
        } else {
            send()
        }
    }

    @discardableResult
    private func registerKeyboardHotkey(_ controller: RecordingController) -> Bool {
        var machine = HotkeyStateMachine(threshold: config.pushToTalkThreshold)
        let apply = makeHotkeyApply(controller, reset: { machine.reset() })
        let down = { apply(machine.keyDown(at: Date())) }
        let up = { apply(machine.keyUp(at: Date())) }

        if let name = config.hotkeyBareModifier, let flag = ModifierHotkey.flag(named: name) {
            let mod = ModifierHotkey(flag: flag)
            mod.onDown = down
            mod.onUp = up
            mod.onInterrupt = { apply(machine.interrupt()) }
            mod.isPresetEnabled = { [weak self] in self?.config.presetHotkeysEnabled ?? false }
            mod.onPresetSelect = { [weak self] slot in
                MainActor.assumeIsolated { self?.activatePreset(slot: slot) }
            }
            mod.register()
            modifierHotkey = mod
            return true  // NSEvent 모니터는 실패를 보고하지 않음 (권한 문제는 bootstrap에서 별도 경고)
        } else {
            hotkey.onDown = down
            hotkey.onUp = up
            return hotkey.register(keyCode: config.hotkeyKeyCode, modifiers: config.hotkeyModifiers)
        }
    }

    /// 트랙패드 손가락 트리거(설정 시). 키보드와 병행하며, 5손가락 펄스를 누름 길이·탭
    /// 횟수로 해석한다: 길게 누름=받아쓰기(PTT), 톡 1번=Enter, 톡 2번=⌘Z 취소.
    /// 빠른 탭이 게이트 debounce에 씹히지 않도록 짧은 debounce(0.05)를 쓴다.
    private func registerTrackpadHotkey(_ controller: RecordingController) {
        guard let fingers = config.trackpadFingerCount else { return }
        // debounce 0 — 살짝 톡 칠 때 5손가락이 닿는 짧은 피크 순간도 즉시 인식한다.
        // (우발은 "N손가락 동시 도달"이라는 강한 조건이 막는다.)
        let mt = MultitouchHotkey(fingerCount: fingers, debounce: 0)
        // hold 0.35s — 5손가락이 순차 안착하는 ~0.1초를 톡이 놓치지 않게, "올리고 잠깐
        // 머물렀다 떼기"를 탭으로 본다(그 이상 유지하면 받아쓰기). 더블탭 윈도우도 함께 넉넉히.
        let recognizer = TapHoldRecognizer(holdThreshold: 0.35, doubleTapWindow: 0.4)

        recognizer.onHoldStart = { [weak self, weak controller, weak recognizer] in
            guard let self, let controller else { return }
            self.beginRecording(controller, reset: { recognizer?.reset() })
            MultitouchHotkey.diag("holdStart — 받아쓰기")
        }
        recognizer.onHoldEnd = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.endRecording(controller)
            MultitouchHotkey.diag("holdEnd — 처리")
        }
        // 키 전송은 5손가락이 완전히 떨어진 뒤(접촉 0)에만. 탭 직후엔 손가락 2개 정도가
        // 아직 닿아 있어, 합성 키 이벤트의 modifier가 누락되거나(⌘Z→z) 키가 씹힌다(Enter 무반응).
        recognizer.onSingleTap = { [weak self, weak controller] in
            guard let self, let controller else { return }
            // 처리 중이면 완료(텍스트 붙은 뒤)에 전송 — "받아쓰고 바로 톡"이 안 씹힌다.
            controller.runWhenIdle { [weak self, weak controller] in
                guard let self, let controller else { return }
                // "paste 안착 후 auto-send": 손가락이 떨어진 뒤,
                // 방금 붙여넣었으면 대상 앱(특히 터미널 PTY)이 ⌘V를 다 먹을 때까지 기다렸다
                // Return을 보낸다. 오래 전 붙여넣었으면 settle이 0이라 즉시 전송.
                self.sendKeyAfterRelease { [weak controller] in
                    let settle = controller?.pasteSettleRemaining() ?? 0
                    DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                        PasteService.postReturn()
                    }
                }
            }
            MultitouchHotkey.diag("singleTap → Return")
        }
        recognizer.onDoubleTap = { [weak self, weak controller] in
            guard let self, let controller, !controller.isBusy,
                  controller.recentDictationUndoable() else { return }
            let count = controller.lastPastedText?.count ?? 0
            controller.markDictationUndone()
            guard count > 0 else { return }
            self.sendKeyAfterRelease { PasteService.postBackspaces(count) }
            MultitouchHotkey.diag("doubleTap → backspace x\(count)")
        }

        // onDown/onUp은 멀티터치 프레임 스레드→메인 디스패치로 들어온다(handleFrame).
        mt.onDown = { [weak recognizer] in MainActor.assumeIsolated { recognizer?.down() } }
        mt.onUp = { [weak recognizer] in MainActor.assumeIsolated { recognizer?.up() } }
        mt.register()
        multitouchHotkey = mt
        tapHoldRecognizer = recognizer
    }
}
