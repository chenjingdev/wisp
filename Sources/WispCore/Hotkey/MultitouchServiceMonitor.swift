import Foundation
import IOKit

/// IORegistry service는 Bluetooth 재연결 때마다 새 ID를 받지만 물리 장치의 serial과
/// `Multitouch ID`는 유지된다. 둘을 함께 보존해야 새로 연결된 다른 트랙패드와 현재
/// 트랙패드의 재열거를 구분할 수 있다.
struct MultitouchServiceIdentity: Equatable {
    let registryID: UInt64
    let multitouchID: UInt64?
    let serialNumber: String?
    let transport: String?
    let builtIn: Bool?
    let vendorID: UInt64?
    let productID: UInt64?
    let familyID: UInt64?
    let locationID: UInt64?

    func isSamePhysicalDevice(as other: Self) -> Bool {
        if let multitouchID, let otherID = other.multitouchID {
            return multitouchID == otherID
        }
        if let serialNumber,
           let otherSerial = other.serialNumber,
           let transport,
           let otherTransport = other.transport,
           let vendorID,
           let otherVendor = other.vendorID,
           let productID,
           let otherProduct = other.productID {
            return serialNumber == otherSerial &&
                transport == otherTransport &&
                vendorID == otherVendor &&
                productID == otherProduct
        }
        if builtIn == true,
           other.builtIn == true,
           let locationID,
           let otherLocation = other.locationID,
           let vendorID,
           let otherVendor = other.vendorID,
           let productID,
           let otherProduct = other.productID {
            let familyMatches =
                familyID == nil || other.familyID == nil || familyID == other.familyID
            return locationID == otherLocation &&
                vendorID == otherVendor &&
                productID == otherProduct &&
                familyMatches
        }
        return false
    }
}

/// matched callback이 실행되는 동안만 유효한 IOService와, 그 service에서 복사한 identity.
/// 소비자는 callback 안에서 동기적으로 `MTDeviceCreateFromService`에 넘겨야 한다.
struct MultitouchService {
    let identity: MultitouchServiceIdentity
    let ioService: io_service_t
}

/// 현재 알려진 AppleMultitouchDevice service identity 집합.
///
/// IOKit matching notification은 같은 service를 중복 전달할 수 있고, 새 service match가
/// old service termination보다 먼저 올 수도 있다. registry entry ID로 멱등 처리하면
/// notification 순서와 Mach port 재사용에 영향받지 않는다.
struct MultitouchServiceTopology {
    private(set) var services: [UInt64: MultitouchServiceIdentity] = [:]

    var serviceIDs: Set<UInt64> {
        Set(services.keys)
    }

    mutating func seed(_ identities: [MultitouchServiceIdentity]) {
        for identity in identities {
            services[identity.registryID] = identity
        }
    }

    mutating func appeared(_ identity: MultitouchServiceIdentity) -> Bool {
        guard services[identity.registryID] == nil else { return false }
        services[identity.registryID] = identity
        return true
    }

    mutating func disappeared(_ id: UInt64) -> MultitouchServiceIdentity? {
        services.removeValue(forKey: id)
    }
}

/// 같은 IOService 안에서 일어나는 power cycle을 down/up 쌍으로 멱등 처리한다.
/// resume 계열 메시지가 중복 도착해도 한 번만 재바인딩한다.
struct MultitouchPowerTransition {
    enum Signal: Equatable {
        case suspended
        case resumed
        case willPowerOff
        case poweredOn
        case other
    }

    private(set) var isPending = false

    /// true면 power-down 뒤 첫 power-up이므로 device stream을 재바인딩해야 한다.
    mutating func observe(_ signal: Signal) -> Bool {
        switch signal {
        case .suspended, .willPowerOff:
            isPending = true
            return false
        case .resumed, .poweredOn:
            guard isPending else { return false }
            isPending = false
            return true
        case .other:
            return false
        }
    }

    mutating func reset() {
        isPending = false
    }
}

/// Bluetooth 연결·절전 복귀 등으로 AppleMultitouchDevice IOService가 재열거되는 사건을
/// 직접 받는다. 정상 idle과 죽은 callback stream을 시간으로 추측하지 않기 위한
/// event-driven 수명주기 신호다.
final class MultitouchServiceMonitor {
    enum Change: CustomStringConvertible, Equatable {
        case appeared(MultitouchService)
        case disappeared(MultitouchServiceIdentity)
        case resumed(MultitouchService)

        var description: String {
            switch self {
            case .appeared(let service):
                "appeared(0x\(String(service.identity.registryID, radix: 16)))"
            case .disappeared(let identity):
                "disappeared(0x\(String(identity.registryID, radix: 16)))"
            case .resumed(let service):
                "resumed(0x\(String(service.identity.registryID, radix: 16)))"
            }
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.appeared(let left), .appeared(let right)):
                left.identity == right.identity && left.ioService == right.ioService
            case (.disappeared(let left), .disappeared(let right)):
                left == right
            case (.resumed(let left), .resumed(let right)):
                left.identity == right.identity && left.ioService == right.ioService
            default:
                false
            }
        }
    }

    private static let serviceClass = "AppleMultitouchDevice"

    private let queue: DispatchQueue
    private let onChange: (Change) -> Void
    private var notificationPort: IONotificationPortRef?
    private var matchedIterator: io_iterator_t = IO_OBJECT_NULL
    private var terminatedIterator: io_iterator_t = IO_OBJECT_NULL
    private var topology = MultitouchServiceTopology()
    private var interestNotifier: io_object_t = IO_OBJECT_NULL
    private var watchedService: io_service_t = IO_OBJECT_NULL
    private var watchedIdentity: MultitouchServiceIdentity?
    private var powerTransition = MultitouchPowerTransition()

    init(queue: DispatchQueue, onChange: @escaping (Change) -> Void) {
        self.queue = queue
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() -> Bool {
        stop()
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return false }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, queue)

        var matched: io_iterator_t = IO_OBJECT_NULL
        let matchedResult = IOServiceAddMatchingNotification(
            port,
            kIOMatchedNotification,
            IOServiceMatching(Self.serviceClass),
            wispMultitouchServiceMatched,
            Unmanaged.passUnretained(self).toOpaque(),
            &matched
        )
        guard matchedResult == KERN_SUCCESS else {
            stop()
            return false
        }
        matchedIterator = matched
        topology.seed(drainIdentities(matched))

        var terminated: io_iterator_t = IO_OBJECT_NULL
        let terminatedResult = IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            IOServiceMatching(Self.serviceClass),
            wispMultitouchServiceTerminated,
            Unmanaged.passUnretained(self).toOpaque(),
            &terminated
        )
        guard terminatedResult == KERN_SUCCESS else {
            stop()
            return false
        }
        terminatedIterator = terminated
        // notification을 arm하기 위한 initial drain. 이 사이 이미 사라진 service가
        // 있다면 topology에서도 제거하되 startup 사건으로 외부에 내보내지는 않는다.
        for identity in drainIdentities(terminated) {
            _ = topology.disappeared(identity.registryID)
        }
        return true
    }

    func stop() {
        stopPowerEvents()
        if matchedIterator != IO_OBJECT_NULL {
            IOObjectRelease(matchedIterator)
            matchedIterator = IO_OBJECT_NULL
        }
        if terminatedIterator != IO_OBJECT_NULL {
            IOObjectRelease(terminatedIterator)
            terminatedIterator = IO_OBJECT_NULL
        }
        if let notificationPort {
            IONotificationPortSetDispatchQueue(notificationPort, nil)
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
        topology = MultitouchServiceTopology()
    }

    /// 활성 MTDevice가 가리키는 exact service의 suspend/resume도 감시한다. service는
    /// 명시적으로 retain해 interest callback과 동기 재바인딩 동안 수명을 보장한다.
    func watchPowerEvents(
        for service: io_service_t,
        identity: MultitouchServiceIdentity
    ) -> Bool {
        guard let notificationPort else { return false }
        if watchedIdentity?.registryID == identity.registryID,
           watchedService != IO_OBJECT_NULL {
            return true
        }

        stopPowerEvents()
        guard IOObjectRetain(service) == KERN_SUCCESS else { return false }
        var notifier: io_object_t = IO_OBJECT_NULL
        let result = IOServiceAddInterestNotification(
            notificationPort,
            service,
            kIOGeneralInterest,
            wispMultitouchServiceInterest,
            Unmanaged.passUnretained(self).toOpaque(),
            &notifier
        )
        guard result == KERN_SUCCESS else {
            if notifier != IO_OBJECT_NULL {
                IOObjectRelease(notifier)
            }
            IOObjectRelease(service)
            return false
        }
        watchedService = service
        watchedIdentity = identity
        interestNotifier = notifier
        powerTransition.reset()
        return true
    }

    private func stopPowerEvents() {
        if interestNotifier != IO_OBJECT_NULL {
            IOObjectRelease(interestNotifier)
            interestNotifier = IO_OBJECT_NULL
        }
        if watchedService != IO_OBJECT_NULL {
            IOObjectRelease(watchedService)
            watchedService = IO_OBJECT_NULL
        }
        watchedIdentity = nil
        powerTransition.reset()
    }

    fileprivate func servicesAppeared(_ iterator: io_iterator_t) {
        drainServices(iterator) { [self] service, identity in
            guard topology.appeared(identity) else { return }
            // `service`는 이 동기 callback이 반환될 때 release된다.
            onChange(.appeared(MultitouchService(identity: identity, ioService: service)))
        }
    }

    fileprivate func servicesDisappeared(_ iterator: io_iterator_t) {
        drainServices(iterator) { [self] _, observedIdentity in
            guard let identity = topology.disappeared(observedIdentity.registryID) else { return }
            if watchedIdentity?.registryID == identity.registryID {
                stopPowerEvents()
            }
            onChange(.disappeared(identity))
        }
    }

    fileprivate func serviceInterest(
        service: io_service_t,
        messageType: UInt32
    ) {
        guard service == watchedService, let watchedIdentity else { return }
        let signal: MultitouchPowerTransition.Signal
        switch messageType {
        case Self.messageServiceIsSuspended:
            signal = .suspended
        case Self.messageServiceIsResumed:
            signal = .resumed
        case Self.messageDeviceWillPowerOff:
            signal = .willPowerOff
        case Self.messageDeviceHasPoweredOn:
            signal = .poweredOn
        default:
            signal = .other
        }
        guard powerTransition.observe(signal) else { return }
        onChange(.resumed(MultitouchService(
            identity: watchedIdentity,
            ioService: watchedService
        )))
    }

    private func drainIdentities(_ iterator: io_iterator_t) -> [MultitouchServiceIdentity] {
        var identities: [MultitouchServiceIdentity] = []
        drainServices(iterator) { _, identity in identities.append(identity) }
        return identities
    }

    private func drainServices(
        _ iterator: io_iterator_t,
        _ body: (io_service_t, MultitouchServiceIdentity) -> Void
    ) {
        while true {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else { break }
            if let identity = Self.identity(for: service) {
                body(service, identity)
            }
            IOObjectRelease(service)
        }
    }

    static func registryID(for service: io_service_t) -> UInt64? {
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS else { return nil }
        return id
    }

    static func identity(for service: io_service_t) -> MultitouchServiceIdentity? {
        guard let registryID = registryID(for: service) else { return nil }
        return MultitouchServiceIdentity(
            registryID: registryID,
            multitouchID: numberProperty("Multitouch ID", service: service),
            serialNumber: stringProperty("SerialNumber", service: service),
            transport: stringProperty("Transport", service: service),
            builtIn: boolProperty("MT Built-In", service: service),
            vendorID: numberProperty("VendorID", service: service),
            productID: numberProperty("ProductID", service: service),
            familyID: numberProperty("Family ID", service: service),
            locationID: numberProperty("LocationID", service: service)
        )
    }

    private static func property(_ key: String, service: io_service_t) -> AnyObject? {
        IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
    }

    private static func numberProperty(_ key: String, service: io_service_t) -> UInt64? {
        (property(key, service: service) as? NSNumber)?.uint64Value
    }

    private static func boolProperty(_ key: String, service: io_service_t) -> Bool? {
        (property(key, service: service) as? NSNumber)?.boolValue
    }

    private static func stringProperty(_ key: String, service: io_service_t) -> String? {
        guard let value = property(key, service: service) as? String, !value.isEmpty else {
            return nil
        }
        return value
    }

    // IOMessage.h의 iokit_common_msg 매크로는 Swift importer가 노출하지 못한다.
    // sys_iokit(0xE0000000) | sub_iokit_common(0) | message.
    private static let messageServiceIsSuspended: UInt32 = 0xE000_0020
    private static let messageServiceIsResumed: UInt32 = 0xE000_0030
    private static let messageDeviceWillPowerOff: UInt32 = 0xE000_0210
    private static let messageDeviceHasPoweredOn: UInt32 = 0xE000_0230
}

private let wispMultitouchServiceMatched: IOServiceMatchingCallback = { refcon, iterator in
    guard let refcon else { return }
    Unmanaged<MultitouchServiceMonitor>
        .fromOpaque(refcon)
        .takeUnretainedValue()
        .servicesAppeared(iterator)
}

private let wispMultitouchServiceTerminated: IOServiceMatchingCallback = { refcon, iterator in
    guard let refcon else { return }
    Unmanaged<MultitouchServiceMonitor>
        .fromOpaque(refcon)
        .takeUnretainedValue()
        .servicesDisappeared(iterator)
}

private let wispMultitouchServiceInterest: IOServiceInterestCallback = {
    refcon, service, messageType, _ in
    guard let refcon else { return }
    Unmanaged<MultitouchServiceMonitor>
        .fromOpaque(refcon)
        .takeUnretainedValue()
        .serviceInterest(service: service, messageType: messageType)
}
