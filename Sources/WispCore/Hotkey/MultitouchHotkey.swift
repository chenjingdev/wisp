import AppKit

/// 트랙패드 멀티터치 전역 트리거. 공개 API로는 전역 손가락 수를 얻을 수 없어
/// 비공개 MultitouchSupport.framework를 dlopen/dlsym으로 사용한다.
///
/// raw callback의 `numTouches`는 실제 접촉 수가 아니라 hover/break/linger를 포함한 path
/// 레코드 수다. `MultitouchFrameDecoder`가 검증된 touch state로 실제 접촉만 세고,
/// `FingerCountGate`가 그 수를 down/up으로 바꾼다.
///
/// 장시간 안정성:
/// - raw frame은 전용 serial queue에서 처리해 main queue backlog를 만들지 않는다.
/// - callback 수신/source frame/per-touch frame 진척을 따로 추적한다.
/// - 녹음 시간은 고장 신호로 사용하지 않는다.
/// - 장애 시 device를 먼저 재연결하고 새 프레임이 hold인지 release인지 판정한다.
/// - unregister → stop → release로 old callback/device를 누수하지 않는다.
/// - sleep/wake에 device를 정상 teardown/recreate한다.
final class MultitouchHotkey {
    var onDown: () -> Void = {}
    var onUp: () -> Void = {}

    /// 현재 실제 접촉 수. 합성 키는 손가락이 완전히 떨어진 뒤 보내야 하므로 외부에서 읽는다.
    var currentCount: Int {
        publicStateLock.lock()
        defer { publicStateLock.unlock() }
        return storedCurrentCount
    }

    private let publicStateLock = NSLock()
    private var storedCurrentCount = 0

    /// C callback 진입 시 활성 device와 세대를 원자적으로 캡처한다. release 직후 새 device가
    /// 같은 포인터 주소를 재사용해도, 이미 큐에 들어간 이전 세대 프레임은 통과하지 못한다.
    private let callbackStateLock = NSLock()
    private var publishedCallbackDevice: UnsafeMutableRawPointer?
    private var publishedCallbackGeneration: UInt64 = 0

    /// device, gate, heartbeat, watchdog 상태를 한 큐에 가둔다. main에는 down/up edge만 보낸다.
    private let inputQueue = DispatchQueue(label: "dev.chenjing.wisp.multitouch-input")
    private let inputQueueKey = DispatchSpecificKey<Void>()
    private var framePeak = 0
    private var rawFramePeak = 0

    private var gate: FingerCountGate
    private let watchdog: MultitouchWatchdog

    // MARK: inputQueue 전용 상태

    private var engaged = false
    /// 첫 stall 뒤 새 device의 스트림이 실제로 다시 진행하는지 확인하는 중.
    private var recoveringDevice = false
    private var recoveryProbe = MultitouchRecoveryProbe()
    private var heartbeat = MultitouchHeartbeat()
    private var didLogLayoutFallback = false
    private var desiredRegistered = false
    private var suspendedForSleep = false
    private var neutralGuard = false
    /// sleep 중 release를 관측할 수 없었던 경우에만 무콜백 neutral 추론을 허용한다.
    /// watchdog 강제 복구는 실제 0-contact 증거가 올 때까지 엄격히 latch를 유지한다.
    private var allowsNoCallbackNeutralFallback = false
    private var nextDeviceRetryAt: TimeInterval = 0
    private var deviceRetryDelay: TimeInterval = 1
    private var watchdogTimer: DispatchSourceTimer?

    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    /// C callback은 refcon이 없어 프로세스당 하나인 트리거를 전역 약참조로 찾는다.
    /// callback thread와 등록/해제 thread가 동시에 접근하므로 weak 참조 자체도 잠근다.
    private static let sharedLock = NSLock()
    private static weak var sharedStorage: MultitouchHotkey?

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    /// 현재 macOS 26.5에서 검증한 callback ABI. 0 반환은 현재 구현에서는 무시되고,
    /// 반환값을 읽는 이후 구현과도 호환된다.
    private typealias MTFrameCallback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32
    ) -> Int32

    private typealias CreateFn = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias RegisterFn = @convention(c) (
        UnsafeMutableRawPointer?, MTFrameCallback
    ) -> Bool
    private typealias UnregisterFn = @convention(c) (
        UnsafeMutableRawPointer?, MTFrameCallback
    ) -> Bool
    private typealias StartFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
    private typealias StopFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias ReleaseFn = @convention(c) (UnsafeMutableRawPointer?) -> Void

    private var mtCreate: CreateFn?
    private var mtRegister: RegisterFn?
    private var mtUnregister: UnregisterFn?
    private var mtStart: StartFn?
    private var mtStop: StopFn?
    private var mtRelease: ReleaseFn?

    /// 현재 활성 device. 교체된 device의 늦은 callback은 포인터와 세대를 함께 비교해 버린다.
    private var device: UnsafeMutableRawPointer?
    private var deviceGeneration: UInt64 = 0

    init(fingerCount: Int,
         debounce: TimeInterval = 0.12,
         stallTimeout: TimeInterval = 1.5) {
        gate = FingerCountGate(target: fingerCount, debounce: debounce)
        watchdog = MultitouchWatchdog(stallTimeout: stallTimeout)
        inputQueue.setSpecific(key: inputQueueKey, value: ())
    }

    /// unified log가 안 잡히는 환경에서도 실기 진단이 남도록 파일에도 기록한다.
    static func diag(_ text: String) {
        let line = "[\(ProcessInfo.processInfo.systemUptime)] \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/wisp_mt.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: url)
        }
    }

    func register() {
        unregister()
        Self.setShared(self)
        installPowerObservers()
        syncOnInputQueue {
            desiredRegistered = true
            startWatchdog()
            _ = attemptDeviceStart(at: ProcessInfo.processInfo.systemUptime)
        }
    }

    func unregister() {
        removePowerObservers()
        syncOnInputQueue {
            desiredRegistered = false
            suspendedForSleep = false
            stopWatchdog()
            stopDevice()
            gate.reset()
            engaged = false
            recoveringDevice = false
            resetRecoveryEvidence()
            neutralGuard = false
            allowsNoCallbackNeutralFallback = false
            resetDeviceRetry()
            setCurrentCount(0)
        }
        Self.clearShared(if: self)
    }

    // MARK: - Sleep / wake

    private func installPowerObservers() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.prepareForSleep()
        }
        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resumeAfterWake()
        }
    }

    private func removePowerObservers() {
        let center = NSWorkspace.shared.notificationCenter
        if let sleepObserver { center.removeObserver(sleepObserver) }
        if let wakeObserver { center.removeObserver(wakeObserver) }
        sleepObserver = nil
        wakeObserver = nil
    }

    private func prepareForSleep() {
        // willSleep notification이 반환되기 전에 callback/device를 완전히 정리한다.
        syncOnInputQueue {
            guard desiredRegistered else { return }
            let wasEngaged = engaged
            neutralGuard = wasEngaged || currentCount > 0
            allowsNoCallbackNeutralFallback = neutralGuard
            suspendedForSleep = true
            stopDevice()
            setCurrentCount(0)
            gate.reset(requireRelease: neutralGuard)
            engaged = false
            recoveringDevice = false
            resetRecoveryEvidence()
            if wasEngaged { emitUp() }
            Self.diag("DEVICE: sleep — unregister/stop/release")
        }
    }

    private func resumeAfterWake() {
        // trackpad service가 깨어날 짧은 여유를 준 뒤 시작한다. 실패하면 watchdog이
        // engaged 여부와 무관하게 지수 backoff로 계속 재시도한다.
        inputQueue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.desiredRegistered, self.suspendedForSleep else { return }
            self.suspendedForSleep = false
            self.resetDeviceRetry()
            _ = self.attemptDeviceStart(at: ProcessInfo.processInfo.systemUptime)
        }
    }

    // MARK: - Framework / device lifecycle

    private func loadSymbols() -> Bool {
        if mtCreate != nil { return true }
        guard let handle = dlopen(Self.frameworkPath, RTLD_LAZY) else {
            NSLog("WISP_MT: MultitouchSupport 로드 실패")
            return false
        }
        // 프레임워크는 프로세스 수명 동안 상주하므로 handle은 닫지 않는다.
        guard let createSym = dlsym(handle, "MTDeviceCreateDefault"),
              let registerSym = dlsym(handle, "MTRegisterContactFrameCallback"),
              let unregisterSym = dlsym(handle, "MTUnregisterContactFrameCallback"),
              let startSym = dlsym(handle, "MTDeviceStart"),
              let stopSym = dlsym(handle, "MTDeviceStop"),
              let releaseSym = dlsym(handle, "MTDeviceRelease")
        else {
            NSLog("WISP_MT: 필수 심볼 없음")
            return false
        }
        mtCreate = unsafeBitCast(createSym, to: CreateFn.self)
        mtRegister = unsafeBitCast(registerSym, to: RegisterFn.self)
        mtUnregister = unsafeBitCast(unregisterSym, to: UnregisterFn.self)
        mtStart = unsafeBitCast(startSym, to: StartFn.self)
        mtStop = unsafeBitCast(stopSym, to: StopFn.self)
        mtRelease = unsafeBitCast(releaseSym, to: ReleaseFn.self)
        return true
    }

    @discardableResult
    private func startDevice() -> Bool {
        guard let create = mtCreate,
              let registerCallback = mtRegister,
              let start = mtStart,
              let dev = create()
        else {
            NSLog("WISP_MT: 트랙패드 장치 생성 실패")
            return false
        }

        device = dev
        deviceGeneration &+= 1
        publishCallbackDevice(dev, generation: deviceGeneration)
        heartbeat.reset(at: ProcessInfo.processInfo.systemUptime)
        didLogLayoutFallback = false
        guard registerCallback(dev, Self.frameCallback) else {
            device = nil
            publishCallbackDevice(nil, generation: deviceGeneration)
            mtRelease?(dev)
            NSLog("WISP_MT: callback 등록 실패")
            return false
        }

        guard start(dev, 0) == 0 else {
            device = nil
            publishCallbackDevice(nil, generation: deviceGeneration)
            _ = mtUnregister?(dev, Self.frameCallback)
            if let stop = mtStop { _ = stop(dev) }
            mtRelease?(dev)
            NSLog("WISP_MT: MTDeviceStart 실패")
            return false
        }
        return true
    }

    private func stopDevice() {
        guard let dev = device else { return }
        // 먼저 nil로 만들어 stop 도중 들어온 callback도 old device로 버린다.
        device = nil
        publishCallbackDevice(nil, generation: deviceGeneration)
        _ = mtUnregister?(dev, Self.frameCallback)
        if let stop = mtStop { _ = stop(dev) }
        mtRelease?(dev)
    }

    @discardableResult
    private func attemptDeviceStart(at now: TimeInterval) -> Bool {
        guard desiredRegistered, !suspendedForSleep else { return false }
        if device != nil { return true }
        guard loadSymbols(), startDevice() else {
            scheduleDeviceRetry(after: now)
            return false
        }

        resetDeviceRetry()
        scheduleNeutralFallback()
        Self.diag("DEVICE: 새 device 등록")
        return true
    }

    /// gate 상태는 보존한다. 새 device가 실제 hold를 보면 녹음을 계속하고, release를 보면
    /// 자연스러운 `.up`을 내게 한다.
    @discardableResult
    private func reregisterDevice() -> Bool {
        stopDevice()
        return attemptDeviceStart(at: ProcessInfo.processInfo.systemUptime)
    }

    private func scheduleDeviceRetry(after now: TimeInterval) {
        nextDeviceRetryAt = now + deviceRetryDelay
        deviceRetryDelay = min(deviceRetryDelay * 2, 30)
        Self.diag("DEVICE: 등록 실패 — \(String(format: "%.0f", nextDeviceRetryAt - now))초 뒤 재시도")
    }

    private func resetDeviceRetry() {
        nextDeviceRetryAt = 0
        deviceRetryDelay = 1
    }

    /// sleep 중 손을 이미 뗐다면 새 device는 0-contact callback을 보내지 않을 수 있다.
    /// 시작 후 callback이 전혀 없으면 neutral로 간주해 첫 정상 제스처를 버리지 않는다.
    private func scheduleNeutralFallback() {
        guard neutralGuard, allowsNoCallbackNeutralFallback else { return }
        let generation = deviceGeneration
        let callbackBaseline = heartbeat.lastCallbackAt
        inputQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self,
                  self.neutralGuard,
                  self.deviceGeneration == generation,
                  self.heartbeat.lastCallbackAt == callbackBaseline
            else { return }
            self.gate.reset()
            self.neutralGuard = false
            self.allowsNoCallbackNeutralFallback = false
            Self.diag("DEVICE: 재등록 후 callback 없음 — neutral로 재무장")
        }
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        stopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: inputQueue)
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
        guard desiredRegistered, !suspendedForSleep else { return }
        guard device != nil else {
            if now >= nextDeviceRetryAt {
                _ = attemptDeviceStart(at: now)
            }
            return
        }

        switch watchdog.evaluate(
            engaged: engaged,
            recoveringDevice: recoveringDevice,
            now: now,
            heartbeat: heartbeat
        ) {
        case .none:
            break

        case .recoverDevice(let reason):
            Self.diag(
                "WATCHDOG: \(reason.rawValue) " +
                "callbackAge=\(age(now, heartbeat.lastCallbackAt)) " +
                "sourceAge=\(age(now, heartbeat.lastSourceProgressAt)) " +
                "contactAge=\(age(now, heartbeat.lastContactProgressAt)) " +
                "— device 재연결 후 실제 접촉 재판정"
            )
            recoveringDevice = true
            resetRecoveryEvidence()
            if !reregisterDevice() {
                forceRelease(reason: reason)
            }

        case .forceRelease(let reason):
            forceRelease(reason: reason)
        }
    }

    /// 재연결이 실패했거나 새 source 스트림도 진행하지 않을 때만 합성 up을 쓴다.
    /// 그 뒤에는 실제 0-contact 프레임을 보기 전까지 gate가 다시 arm되지 않아
    /// 즉시 재녹음되는 bounce를 막는다.
    private func forceRelease(reason: MultitouchWatchdog.StallReason) {
        Self.diag(
            "WATCHDOG: 재연결 후에도 \(reason.rawValue) — 합성 up, neutral 전 재무장 금지"
        )
        let wasEngaged = engaged
        gate.reset(requireRelease: true)
        neutralGuard = true
        allowsNoCallbackNeutralFallback = false
        engaged = false
        recoveringDevice = false
        resetRecoveryEvidence()
        // 첫 재연결 자체가 실패한 경우에는 이미 독립 retry가 예약돼 있다. 살아 있지만
        // 새 stream도 멎은 device만 여기서 한 번 더 정상 teardown/recreate한다.
        if device != nil { _ = reregisterDevice() }
        if wasEngaged { emitUp() }
    }

    private func age(_ now: TimeInterval, _ then: TimeInterval) -> String {
        String(format: "%.1fs", max(0, now - then))
    }

    // MARK: - Raw frame → semantic edge

    /// touches 포인터가 유효한 callback 안에서 Swift 값으로 복사한 뒤 전용 큐로 넘긴다.
    private func receiveFrame(device: UnsafeMutableRawPointer?,
                              touches: UnsafeMutableRawPointer?,
                              reportedCount: Int,
                              sourceTimestamp: TimeInterval,
                              sourceFrame: Int32) {
        guard let generation = callbackGeneration(for: device) else { return }
        let receivedAt = ProcessInfo.processInfo.systemUptime
        let frame = MultitouchFrameDecoder.decode(
            touches: touches,
            reportedCount: reportedCount,
            sourceTimestamp: sourceTimestamp,
            sourceFrame: sourceFrame
        )
        inputQueue.async { [weak self] in
            self?.handleFrame(
                device: device,
                generation: generation,
                frame: frame,
                receivedAt: receivedAt
            )
        }
    }

    private func handleFrame(device callbackDevice: UnsafeMutableRawPointer?,
                             generation callbackGeneration: UInt64,
                             frame: MultitouchFrame,
                             receivedAt: TimeInterval) {
        guard callbackDevice == device, callbackGeneration == deviceGeneration else { return }

        heartbeat.observe(frame, receivedAt: receivedAt)
        if recoveringDevice {
            switch recoveryProbe.observe(frame) {
            case .first:
                Self.diag(
                    "WATCHDOG: 새 device 첫 프레임 count=\(frame.physicalCount) " +
                    "— source 연속 진행 확인 중"
                )
                return
            case .replay:
                return
            case .progressing:
                recoveringDevice = false
                Self.diag(
                    "WATCHDOG: 새 device source 연속 진행 확인 count=\(frame.physicalCount) " +
                    "— 기존 hold 상태로 계속 판정"
                )
            }
        }
        if !frame.touchLayoutValid, !didLogLayoutFallback {
            didLogLayoutFallback = true
            Self.diag(
                "MTTouch ABI 검증 실패 — state 필터 대신 raw count + source heartbeat 사용"
            )
        }

        let count = frame.physicalCount
        if neutralGuard && count == 0 {
            neutralGuard = false
            allowsNoCallbackNeutralFallback = false
        }
        setCurrentCount(count)
        framePeak = max(framePeak, count)
        rawFramePeak = max(rawFramePeak, frame.reportedCount)
        if count == 0 && framePeak > 0 {
            Self.diag(
                "접촉 종료 physicalPeak=\(framePeak) rawPeak=\(rawFramePeak) " +
                frame.stateSummary
            )
            framePeak = 0
            rawFramePeak = 0
        }

        switch gate.update(count: count, now: receivedAt) {
        case .down:
            engaged = true
            emitDown()
        case .up:
            engaged = false
            recoveringDevice = false
            resetRecoveryEvidence()
            emitUp()
        case .none:
            break
        }
    }

    private func setCurrentCount(_ count: Int) {
        publicStateLock.lock()
        storedCurrentCount = count
        publicStateLock.unlock()
    }

    private func emitDown() {
        DispatchQueue.main.async { [weak self] in self?.onDown() }
    }

    private func emitUp() {
        DispatchQueue.main.async { [weak self] in self?.onUp() }
    }

    private func resetRecoveryEvidence() {
        recoveryProbe.reset()
    }

    private func publishCallbackDevice(_ device: UnsafeMutableRawPointer?,
                                       generation: UInt64) {
        callbackStateLock.lock()
        publishedCallbackDevice = device
        publishedCallbackGeneration = generation
        callbackStateLock.unlock()
    }

    private func callbackGeneration(for callbackDevice: UnsafeMutableRawPointer?) -> UInt64? {
        callbackStateLock.lock()
        defer { callbackStateLock.unlock() }
        guard callbackDevice != nil, callbackDevice == publishedCallbackDevice else { return nil }
        return publishedCallbackGeneration
    }

    private static func setShared(_ instance: MultitouchHotkey) {
        sharedLock.lock()
        sharedStorage = instance
        sharedLock.unlock()
    }

    private static func clearShared(if instance: MultitouchHotkey) {
        sharedLock.lock()
        if sharedStorage === instance { sharedStorage = nil }
        sharedLock.unlock()
    }

    private static func currentShared() -> MultitouchHotkey? {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        return sharedStorage
    }

    /// 해제가 inputQueue의 마지막 작업에서 일어나도 자기 자신을 sync 대기하지 않는다.
    private func syncOnInputQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: inputQueueKey) != nil {
            work()
        } else {
            inputQueue.sync(execute: work)
        }
    }

    private static let frameCallback: MTFrameCallback = {
        device, touches, numTouches, timestamp, frame in
        MultitouchHotkey.currentShared()?.receiveFrame(
            device: device,
            touches: touches,
            reportedCount: Int(numTouches),
            sourceTimestamp: timestamp,
            sourceFrame: frame
        )
        return 0
    }

    deinit {
        Self.clearShared(if: self)
        removePowerObservers()
        syncOnInputQueue {
            stopWatchdog()
            stopDevice()
        }
    }
}
