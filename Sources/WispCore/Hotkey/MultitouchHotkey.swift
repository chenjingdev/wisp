import AppKit
import IOKit

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
/// - callback publish 해제 → stop → unregister → release 순서로 stream queue를 drain한다.
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
    private var recoveryFrames = MultitouchRecoveryFrameFilter()
    /// 어떤 원인으로 재바인딩하든 직전 service ID를 보존한다. 성공 뒤 ID가 달라졌다면
    /// matched notification보다 watchdog이 먼저 실행됐어도 새 generation으로 확정한다.
    private var recoveryOldServiceID: UInt64?
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
    private typealias CreateFromServiceFn = @convention(c) (
        io_service_t
    ) -> UnsafeMutableRawPointer?
    private typealias RegisterFn = @convention(c) (
        UnsafeMutableRawPointer?, MTFrameCallback
    ) -> Bool
    private typealias UnregisterFn = @convention(c) (
        UnsafeMutableRawPointer?, MTFrameCallback
    ) -> Bool
    private typealias StartFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
    private typealias StopFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias ReleaseFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias GetServiceFn = @convention(c) (UnsafeMutableRawPointer?) -> io_service_t

    private var mtCreate: CreateFn?
    private var mtCreateFromService: CreateFromServiceFn?
    private var mtRegister: RegisterFn?
    private var mtUnregister: UnregisterFn?
    private var mtStart: StartFn?
    private var mtStop: StopFn?
    private var mtRelease: ReleaseFn?
    private var mtGetService: GetServiceFn?

    /// 현재 활성 device. 교체된 device의 늦은 callback은 포인터와 세대를 함께 비교해 버린다.
    private var device: UnsafeMutableRawPointer?
    private var deviceGeneration: UInt64 = 0
    private var activeServiceIdentity: MultitouchServiceIdentity?
    /// 첫 default device의 물리 identity를 latch한다. 다른 트랙패드 match로 갈아타지 않는다.
    private var wantedServiceIdentity: MultitouchServiceIdentity?
    /// exact matched service start가 잠시 실패해도 CreateDefault로 되돌아가지 않도록 retain한다.
    private var pendingExactService: MultitouchService?
    private var serviceMonitor: MultitouchServiceMonitor?

    private var activeServiceID: UInt64? {
        activeServiceIdentity?.registryID
    }

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
            startServiceMonitor()
            startWatchdog()
            _ = attemptDeviceStart(at: ProcessInfo.processInfo.systemUptime)
        }
    }

    func unregister() {
        removePowerObservers()
        syncOnInputQueue {
            desiredRegistered = false
            suspendedForSleep = false
            stopServiceMonitor()
            stopWatchdog()
            stopDevice()
            gate.reset()
            engaged = false
            recoveryFrames.clear()
            recoveryOldServiceID = nil
            clearPendingExactService()
            wantedServiceIdentity = nil
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
            recoveryFrames.clear()
            recoveryOldServiceID = nil
            clearPendingExactService()
            if wasEngaged { emitUp() }
            Self.diag("DEVICE: sleep — stop/unregister/release")
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
              let createFromServiceSym = dlsym(handle, "MTDeviceCreateFromService"),
              let registerSym = dlsym(handle, "MTRegisterContactFrameCallback"),
              let unregisterSym = dlsym(handle, "MTUnregisterContactFrameCallback"),
              let startSym = dlsym(handle, "MTDeviceStart"),
              let stopSym = dlsym(handle, "MTDeviceStop"),
              let releaseSym = dlsym(handle, "MTDeviceRelease"),
              let getServiceSym = dlsym(handle, "MTDeviceGetService")
        else {
            NSLog("WISP_MT: 필수 심볼 없음")
            return false
        }
        mtCreate = unsafeBitCast(createSym, to: CreateFn.self)
        mtCreateFromService = unsafeBitCast(
            createFromServiceSym,
            to: CreateFromServiceFn.self
        )
        mtRegister = unsafeBitCast(registerSym, to: RegisterFn.self)
        mtUnregister = unsafeBitCast(unregisterSym, to: UnregisterFn.self)
        mtStart = unsafeBitCast(startSym, to: StartFn.self)
        mtStop = unsafeBitCast(stopSym, to: StopFn.self)
        mtRelease = unsafeBitCast(releaseSym, to: ReleaseFn.self)
        mtGetService = unsafeBitCast(getServiceSym, to: GetServiceFn.self)
        return true
    }

    @discardableResult
    private func startDevice(using service: MultitouchService? = nil) -> Bool {
        guard let create = mtCreate,
              let registerCallback = mtRegister,
              let start = mtStart
        else {
            NSLog("WISP_MT: 트랙패드 장치 생성 실패")
            return false
        }
        let dev: UnsafeMutableRawPointer?
        if let service, let createFromService = mtCreateFromService {
            dev = createFromService(service.ioService)
        } else {
            dev = create()
        }
        guard let dev else {
            NSLog("WISP_MT: 트랙패드 장치 생성 실패")
            return false
        }
        let candidateIdentity = serviceIdentity(for: dev) ?? service?.identity
        if let wantedServiceIdentity {
            guard let candidateIdentity,
                  wantedServiceIdentity.isSamePhysicalDevice(as: candidateIdentity)
            else {
                mtRelease?(dev)
                Self.diag("DEVICE: default가 선택된 물리 트랙패드와 달라 대기")
                return false
            }
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
            if let stop = mtStop { _ = stop(dev) }
            _ = mtUnregister?(dev, Self.frameCallback)
            mtRelease?(dev)
            NSLog("WISP_MT: MTDeviceStart 실패")
            return false
        }
        activeServiceIdentity = candidateIdentity
        if wantedServiceIdentity == nil {
            wantedServiceIdentity = candidateIdentity
        }
        if let candidateIdentity,
           let ioService = mtGetService?(dev),
           ioService != IO_OBJECT_NULL,
           serviceMonitor?.watchPowerEvents(
               for: ioService,
               identity: candidateIdentity
           ) == false {
            Self.diag("DEVICE: IOKit power monitor 등록 실패")
        }
        return true
    }

    private func stopDevice() {
        guard let dev = device else { return }
        // 먼저 publish를 끊고, MTDeviceStop의 내부 barrier로 stream callback을 drain한 뒤
        // callback table을 바꾼다. unregister를 먼저 하면 stream queue와 경쟁할 수 있다.
        device = nil
        activeServiceIdentity = nil
        publishCallbackDevice(nil, generation: deviceGeneration)
        if let stop = mtStop { _ = stop(dev) }
        _ = mtUnregister?(dev, Self.frameCallback)
        mtRelease?(dev)
    }

    @discardableResult
    private func attemptDeviceStart(
        at now: TimeInterval,
        using service: MultitouchService? = nil
    ) -> Bool {
        guard desiredRegistered, !suspendedForSleep else { return false }
        if device != nil { return true }
        let exactService = service ?? pendingExactService
        guard loadSymbols(), startDevice(using: exactService) else {
            scheduleDeviceRetry(after: now)
            return false
        }

        if engaged,
           let oldServiceID = recoveryOldServiceID,
           let newServiceID = activeServiceID {
            recoveryFrames.finishRebind(
                previousServiceID: oldServiceID,
                boundServiceID: newServiceID
            )
            recoveryOldServiceID = nil
        }
        clearPendingExactService()
        resetDeviceRetry()
        scheduleNeutralFallback()
        let serviceText = activeServiceID.map { "0x\(String($0, radix: 16))" } ?? "unknown"
        Self.diag("DEVICE: 새 device 등록 service=\(serviceText)")
        return true
    }

    /// gate 상태는 보존한다. 새 device가 실제 hold를 보면 녹음을 계속하고, release를 보면
    /// 자연스러운 `.up`을 내게 한다.
    @discardableResult
    private func reregisterDevice(using service: MultitouchService? = nil) -> Bool {
        if engaged {
            recoveryOldServiceID =
                activeServiceID ?? recoveryOldServiceID ?? wantedServiceIdentity?.registryID
            recoveryFrames.beginSameServiceProbe()
        }
        stopDevice()
        return attemptDeviceStart(
            at: ProcessInfo.processInfo.systemUptime,
            using: service
        )
    }

    @discardableResult
    private func rememberExactService(_ service: MultitouchService) -> Bool {
        if pendingExactService?.identity.registryID == service.identity.registryID {
            return true
        }
        clearPendingExactService()
        guard IOObjectRetain(service.ioService) == KERN_SUCCESS else { return false }
        pendingExactService = service
        return true
    }

    private func clearPendingExactService() {
        guard let pendingExactService else { return }
        IOObjectRelease(pendingExactService.ioService)
        self.pendingExactService = nil
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
            recoveringDevice: recoveryFrames.isRecovering,
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
            // 유휴라면 새 device로 갈아끼우기만 한다. 녹음 중이면 gate/engaged를
            // 보존하고 새 source가 실제 hold/release를 보여줄 때까지 기다린다.
            // 재등록이 잠시 실패해도 시간만으로 녹음을 끊지 않고 독립 retry가 계속한다.
            if !reregisterDevice(), engaged {
                Self.diag("WATCHDOG: device 없음 — 녹음 상태 보존, 재연결 대기")
            }

        }
    }

    private func age(_ now: TimeInterval, _ then: TimeInterval) -> String {
        String(format: "%.1fs", max(0, now - then))
    }

    // MARK: - IOKit device service lifecycle

    /// 정상 idle에는 contact callback이 없으므로 heartbeat의 시간만 보고 stream 사망을
    /// 판정할 수 없다. 대신 Bluetooth 트랙패드가 재연결되며 AppleMultitouchDevice
    /// IOService가 교체되는 사건을 직접 구독한다.
    private func startServiceMonitor() {
        let monitor = MultitouchServiceMonitor(queue: inputQueue) { [weak self] change in
            self?.handleServiceChange(change)
        }
        guard monitor.start() else {
            Self.diag("DEVICE: IOKit service monitor 등록 실패")
            return
        }
        serviceMonitor = monitor
        Self.diag("DEVICE: IOKit service monitor 등록")
    }

    private func stopServiceMonitor() {
        serviceMonitor?.stop()
        serviceMonitor = nil
    }

    private func handleServiceChange(_ change: MultitouchServiceMonitor.Change) {
        guard desiredRegistered, !suspendedForSleep else { return }

        switch change {
        case .appeared(let service):
            let identity = service.identity
            // 현재 device가 이미 이 service에 묶여 있으면 초기/중복 notification이다.
            guard identity.registryID != activeServiceID else { return }

            // 첫 startup 전에는 exact candidate를 임의로 고르지 않고 framework의 default
            // 선택을 따른다. 한번 선택된 뒤에는 같은 물리 identity의 새 generation만 받는다.
            if let wantedServiceIdentity {
                guard wantedServiceIdentity.isSamePhysicalDevice(as: identity) else {
                    Self.diag("DEVICE: 다른 multitouch service \(change) — 무시")
                    return
                }
            }
            Self.diag("DEVICE: IOKit topology \(change) — exact service 재등록")
            let replacement: MultitouchService?
            if wantedServiceIdentity == nil {
                replacement = nil
            } else {
                _ = rememberExactService(service)
                replacement = service
            }
            if !reregisterDevice(using: replacement), engaged {
                Self.diag("DEVICE: service 교체 중 — 녹음 상태 보존, 재연결 대기")
            }

        case .disappeared(let identity):
            if pendingExactService?.identity.registryID == identity.registryID {
                clearPendingExactService()
            }
            // 새 service가 먼저 나타난 뒤 old termination이 늦게 오는 순서를 허용한다.
            guard identity.registryID == activeServiceID else { return }
            Self.diag("DEVICE: IOKit topology \(change) — default service 재등록")
            if !reregisterDevice(), engaged {
                Self.diag("DEVICE: service 교체 중 — 녹음 상태 보존, 재연결 대기")
            }

        case .resumed(let service):
            guard service.identity.registryID == activeServiceID else { return }
            Self.diag("DEVICE: IOKit power \(change) — exact service 재등록")
            _ = rememberExactService(service)
            if !reregisterDevice(using: service), engaged {
                Self.diag("DEVICE: power 복귀 중 — 녹음 상태 보존, 재연결 대기")
            }
        }
    }

    private func serviceIdentity(
        for device: UnsafeMutableRawPointer
    ) -> MultitouchServiceIdentity? {
        guard let service = mtGetService?(device), service != IO_OBJECT_NULL else { return nil }
        return MultitouchServiceMonitor.identity(for: service)
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
        switch recoveryFrames.observe(frame, boundServiceID: activeServiceID) {
        case .accept:
            break
        case .waitForProgress, .waitForExpectedReplacement:
            return
        case .acceptedProgress:
            Self.diag(
                "WATCHDOG: 새 device source 연속 진행 확인 count=\(frame.physicalCount) " +
                "— 기존 hold 상태로 계속 판정"
            )
        case .acceptedReplacement:
            Self.diag(
                "DEVICE: 새 service 첫 프레임 신뢰 count=\(frame.physicalCount) " +
                "— 실제 hold/release 판정"
            )
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
            recoveryFrames.clear()
            recoveryOldServiceID = nil
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
            desiredRegistered = false
            stopServiceMonitor()
            stopWatchdog()
            stopDevice()
            clearPendingExactService()
        }
    }
}
