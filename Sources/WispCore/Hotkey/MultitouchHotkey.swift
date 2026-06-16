import Foundation

/// 트랙패드 멀티터치 전역 트리거. 공개 API로는 전역 손가락 수를 얻을 수 없어
/// 비공개 MultitouchSupport.framework를 dlopen/dlsym으로 사용한다(BetterTouchTool
/// 등이 쓰는 방식). 프레임 콜백이 주는 접촉 수를 FingerCountGate가 누름/뗌으로 바꾸고,
/// 호출자(TapHoldRecognizer)는 그 펄스를 길게 누름/탭으로 해석한다.
///
/// 한계(중요): 비공개 API라 향후 macOS에서 동작이 바뀌거나 끊길 수 있다. 실제 터치
/// 감지는 헤드리스로 검증 불가하다 — 누름/뗌 판정 로직(FingerCountGate)과 stall 판정
/// (MultitouchWatchdog)만 단위 테스트하고, 콜백 경로는 실기에서 확인해야 한다.
///
/// 장시간 안정성(watchdog): 실측상 앱을 ~19시간 띄워두면 프레임 콜백이 stale해져
/// "뗌" 프레임을 빠뜨린다 → `.up`이 안 나가 녹음이 `.recording`에 갇히고 이후 제스처가
/// 전부 무시된다. 프레임에 의존하지 않는 독립 타이머가 마지막 프레임 시각을 보고
/// (1) 녹음 중 프레임 stall → 합성 `up`+device 재등록으로 복구, (2) 유휴 시 주기
/// 재등록으로 예방한다. 재등록 후 old device의 늦은 콜백은 device 포인터로 걸러낸다.
///
/// 스레드: 콜백은 멀티터치 프레임 스레드에서 온다. 게이트 평가와 onDown/onUp 호출,
/// watchdog tick은 메인으로 디스패치한다.
final class MultitouchHotkey {
    var onDown: () -> Void = {}
    var onUp: () -> Void = {}

    /// 현재 접촉 수(메인스레드에서만 갱신). 탭 액션을 손가락이 완전히 떨어진 뒤
    /// 보내려고 호출자가 폴링한다 — 잔여 접촉 중엔 합성 키의 modifier가 누락된다(⌘Z→z).
    private(set) var currentCount = 0
    private var framePeak = 0   // 진단: 한 번의 접촉에서 도달한 최대 손가락 수

    private var gate: FingerCountGate
    private let watchdog: MultitouchWatchdog

    // MARK: watchdog 상태 (메인스레드에서만 접근)
    /// FingerCountGate가 `.down`을 냈고 아직 `.up`을 안 낸 상태(=녹음 중으로 간주).
    private var engaged = false
    /// 마지막 프레임 수신 시각 — stall 판정 기준.
    private var lastFrameAt: TimeInterval = 0
    /// 마지막으로 device를 (재)등록한 시각 — 유휴 주기 재등록 기준.
    private var lastDeviceStartAt: TimeInterval = 0
    private var watchdogTimer: DispatchSourceTimer?

    /// C 콜백은 컨텍스트 인자를 받지 않는 시그니처라(refcon 없음) 전역 약참조로
    /// 살아있는 인스턴스를 찾는다. 트리거는 프로세스당 하나뿐이라 충분하다.
    private static weak var shared: MultitouchHotkey?

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    /// 프레임 콜백. OpenMultitouchSupport(검증된 레퍼런스)의 정확한 시그니처:
    ///   void (*)(MTDeviceRef device, MTTouch touches[], int numTouches, double timestamp, int frame)
    /// touches 포인터는 쓰지 않으므로 raw pointer로만 받고, 반환은 void다. device는 재등록
    /// 후 old device의 늦은 콜백을 걸러내는 데 쓴다(활성 device와 다르면 무시).
    private typealias MTFrameCallback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32
    ) -> Void

    // 멀티터치 심볼 — dlopen/dlsym은 1회만 하고, 재등록 때는 device만 재생성한다.
    private typealias CreateFn = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias RegisterFn = @convention(c) (UnsafeMutableRawPointer?, MTFrameCallback) -> Void
    private typealias StartFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
    private typealias StopFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private var mtCreate: CreateFn?
    private var mtRegister: RegisterFn?
    private var mtStart: StartFn?
    private var mtStop: StopFn?

    /// 현재 활성 device. 재등록으로 교체된 old device의 늦은 콜백을 이 포인터로 걸러낸다.
    private var device: UnsafeMutableRawPointer?

    init(fingerCount: Int, debounce: TimeInterval = 0.12,
         stallTimeout: TimeInterval = 1.5,
         idleReregisterInterval: TimeInterval = 1800) {
        self.gate = FingerCountGate(target: fingerCount, debounce: debounce)
        self.watchdog = MultitouchWatchdog(stallTimeout: stallTimeout,
                                           idleReregisterInterval: idleReregisterInterval)
    }

    /// 진단: unified log(NSLog)가 안 잡히는 환경이라 파일로도 남긴다. (검증 끝나면 제거)
    static func diag(_ s: String) {
        let line = "[\(ProcessInfo.processInfo.systemUptime)] \(s)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/wisp_mt.log")
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            h.seekToEndOfFile(); h.write(data)
        } else {
            try? data.write(to: url)
        }
    }

    func register() {
        unregister()
        guard loadSymbols() else { return }
        guard startDevice() else { return }
        Self.shared = self
        startWatchdog()
    }

    func unregister() {
        stopWatchdog()
        stopDevice()
        gate.reset()
        engaged = false
        if Self.shared === self { Self.shared = nil }
    }

    // MARK: - 심볼 로드 / device 생명주기

    /// dlopen/dlsym은 프로세스 수명 동안 1회면 충분 — 재등록 때 다시 풀지 않는다.
    private func loadSymbols() -> Bool {
        if mtCreate != nil { return true }
        guard let handle = dlopen(Self.frameworkPath, RTLD_LAZY) else {
            NSLog("WISP_MT: MultitouchSupport 로드 실패"); return false
        }
        // 프레임워크는 프로세스 수명 동안 상주 — handle을 닫지 않는다.
        guard let createSym = dlsym(handle, "MTDeviceCreateDefault"),
              let registerSym = dlsym(handle, "MTRegisterContactFrameCallback"),
              let startSym = dlsym(handle, "MTDeviceStart"),
              let stopSym = dlsym(handle, "MTDeviceStop")
        else { NSLog("WISP_MT: 심볼 없음"); return false }
        mtCreate = unsafeBitCast(createSym, to: CreateFn.self)
        mtRegister = unsafeBitCast(registerSym, to: RegisterFn.self)
        mtStart = unsafeBitCast(startSym, to: StartFn.self)
        mtStop = unsafeBitCast(stopSym, to: StopFn.self)
        return true
    }

    /// device를 생성·콜백 등록·시작한다. watchdog 기준 시각(lastDeviceStartAt/lastFrameAt)도 초기화.
    @discardableResult
    private func startDevice() -> Bool {
        guard let create = mtCreate, let registerCb = mtRegister, let start = mtStart else { return false }
        guard let dev = create() else {
            NSLog("WISP_MT: 트랙패드 장치 없음(MTDeviceCreateDefault nil)"); return false
        }
        device = dev
        registerCb(dev, Self.frameCallback)
        _ = start(dev, 0)
        let now = ProcessInfo.processInfo.systemUptime
        lastDeviceStartAt = now
        lastFrameAt = now   // 갓 시작 — 아직 stall 아님
        return true
    }

    private func stopDevice() {
        if let dev = device, let stop = mtStop { _ = stop(dev) }
        device = nil
    }

    /// stall/유휴 시 device를 재생성한다(심볼은 유지). 메인에서만 호출.
    private func reregisterDevice() {
        stopDevice()
        _ = startDevice()
    }

    // MARK: - watchdog

    private func startWatchdog() {
        stopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.tickWatchdog() }
        watchdogTimer = timer
        timer.resume()
    }

    private func stopWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    private func tickWatchdog() {
        let now = ProcessInfo.processInfo.systemUptime
        switch watchdog.evaluate(engaged: engaged, currentCount: currentCount, now: now,
                                 lastFrameAt: lastFrameAt, lastDeviceStartAt: lastDeviceStartAt) {
        case .none:
            break
        case .recoverStuck:
            Self.diag("WATCHDOG: 녹음 중 프레임 stall \(String(format: "%.1f", now - lastFrameAt))s — 합성 up + 재등록")
            // 콜백이 stale해 "뗌"을 못 받은 상태 — 게이트를 풀고 device를 재생성한 뒤,
            // 합성 up으로 갇힌 녹음을 정상 종료시킨다(onUp → recognizer → stopAndProcess).
            gate.reset()
            engaged = false
            reregisterDevice()
            onUp()
        case .reregisterIdle:
            Self.diag("WATCHDOG: 유휴 \(String(format: "%.0f", now - lastDeviceStartAt))s — device 주기 재등록")
            reregisterDevice()
        }
    }

    // MARK: - 프레임 처리

    // 멀티터치 스레드에서 호출됨 — 게이트 평가·콜백은 메인에서.
    private func handleFrame(device: UnsafeMutableRawPointer?, count: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 재등록으로 교체된 old device의 늦은 콜백은 무시한다(새 상태 오염 방지).
            guard device == self.device else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.lastFrameAt = now
            self.currentCount = count
            self.framePeak = max(self.framePeak, count)
            if count == 0 && self.framePeak > 0 {
                Self.diag("접촉 종료 peak=\(self.framePeak)")
                self.framePeak = 0
            }
            switch self.gate.update(count: count, now: now) {
            case .down: self.engaged = true; self.onDown()
            case .up: self.engaged = false; self.onUp()
            case .none: break
            }
        }
    }

    private static let frameCallback: MTFrameCallback = { device, _, numTouches, _, _ in
        MultitouchHotkey.shared?.handleFrame(device: device, count: Int(numTouches))
    }

    deinit { stopWatchdog(); stopDevice() }
}
