import Foundation
@testable import WispCore

@MainActor
func multitouchWatchdogTests(_ t: TestRunner) async {
    func frame(source: Int32,
               timestamp: TimeInterval,
               physicalCount: Int = 5,
               touchFrame: Int32? = nil,
               layoutValid: Bool = true) -> MultitouchFrame {
        MultitouchFrame(
            reportedCount: physicalCount,
            physicalCount: physicalCount,
            sourceTimestamp: timestamp,
            sourceFrame: source,
            newestPhysicalTouchFrame: touchFrame ?? (physicalCount > 0 ? source : nil),
            stateCounts: layoutValid ? Array(repeating: 0, count: 8) : [],
            touchLayoutValid: layoutValid
        )
    }

    func decodedFrame(states: [Int32],
                      touchFrames: [Int32],
                      sourceFrame: Int32 = 42) -> MultitouchFrame {
        let byteCount = max(1, states.count) * MultitouchFrameDecoder.touchStride
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 8)
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        defer { pointer.deallocate() }

        for index in states.indices {
            let base = index * MultitouchFrameDecoder.touchStride
            pointer.storeBytes(
                of: touchFrames[index],
                toByteOffset: base + MultitouchFrameDecoder.frameOffset,
                as: Int32.self
            )
            pointer.storeBytes(
                of: states[index],
                toByteOffset: base + MultitouchFrameDecoder.stateOffset,
                as: Int32.self
            )
        }
        return MultitouchFrameDecoder.decode(
            touches: pointer,
            reportedCount: states.count,
            sourceTimestamp: 12.5,
            sourceFrame: sourceFrame
        )
    }

    func serviceIdentity(
        registryID: UInt64,
        multitouchID: UInt64? = nil,
        serial: String? = nil,
        transport: String? = "Bluetooth",
        builtIn: Bool? = false,
        vendorID: UInt64? = 76,
        productID: UInt64? = 613,
        familyID: UInt64? = 129,
        locationID: UInt64? = nil
    ) -> MultitouchServiceIdentity {
        MultitouchServiceIdentity(
            registryID: registryID,
            multitouchID: multitouchID,
            serialNumber: serial,
            transport: transport,
            builtIn: builtIn,
            vendorID: vendorID,
            productID: productID,
            familyID: familyID,
            locationID: locationID
        )
    }

    await t.test("MultitouchFrame: raw path 중 MakeTouch/Touching만 실제 접촉으로 계산") {
        let decoded = decodedFrame(
            states: [3, 4, 5, 6, 7],
            touchFrames: [42, 42, 42, 42, 42]
        )
        try expectEqual(decoded.reportedCount, 5)
        try expectEqual(decoded.physicalCount, 2)
        try expectEqual(decoded.newestPhysicalTouchFrame, 42)
        try expectEqual(decoded.touchLayoutValid, true)
        try expectEqual(decoded.stateCounts, [0, 0, 0, 1, 1, 1, 1, 1])
    }

    await t.test("MultitouchFrame: ABI 검증 실패 시 raw count로 안전 폴백") {
        // 두 번째 touch record frame이 callback source frame과 다르면 stride/layout을
        // 신뢰하지 않고 기존 numTouches 판정으로 돌아간다.
        let decoded = decodedFrame(
            states: [4, 4, 6],
            touchFrames: [42, 41, 42]
        )
        try expectEqual(decoded.reportedCount, 3)
        try expectEqual(decoded.physicalCount, 3)
        try expectEqual(decoded.touchLayoutValid, false)
        try expectEqual(decoded.newestPhysicalTouchFrame, nil)
    }

    await t.test("MultitouchHeartbeat: callback 도착과 source/contact 진행을 구분") {
        var heartbeat = MultitouchHeartbeat(now: 0)
        let first = frame(source: 10, timestamp: 1.0)
        heartbeat.observe(first, receivedAt: 1.0)

        // 같은 source/touch frame replay: callback만 새롭고 source/contact는 1.0에 머문다.
        heartbeat.observe(first, receivedAt: 2.0)
        try expectEqual(heartbeat.lastCallbackAt, 2.0)
        try expectEqual(heartbeat.lastSourceProgressAt, 1.0)
        try expectEqual(heartbeat.lastContactProgressAt, 1.0)

        // 다른 identity여도 timestamp가 뒤로 가는 A/B replay는 진척이 아니다.
        heartbeat.observe(frame(source: 9, timestamp: 0.9), receivedAt: 2.5)
        try expectEqual(heartbeat.lastSourceProgressAt, 1.0)

        let next = frame(source: 11, timestamp: 1.1)
        heartbeat.observe(next, receivedAt: 3.0)
        try expectEqual(heartbeat.lastSourceProgressAt, 3.0)
        try expectEqual(heartbeat.lastContactProgressAt, 3.0)
    }

    await t.test("MultitouchRecoveryProbe: replay 한 장이 아니라 source 연속 진행을 확인") {
        var probe = MultitouchRecoveryProbe()
        let first = frame(source: 50, timestamp: 7.0)
        try expectEqual(probe.observe(first), .first)
        try expectEqual(probe.observe(first), .replay)
        try expectEqual(probe.observe(frame(source: 49, timestamp: 6.9)), .replay)
        try expectEqual(probe.observe(frame(source: 51, timestamp: 7.1)), .replay)
        try expectEqual(probe.observe(frame(source: 52, timestamp: 7.2)), .progressing)

        probe.reset()
        try expectEqual(probe.observe(frame(source: 90, timestamp: 9.0)), .first)
    }

    await t.test("MultitouchRecoveryProbe: A/B stale 교대는 진행으로 오인하지 않음") {
        var probe = MultitouchRecoveryProbe()
        try expectEqual(probe.observe(frame(source: 10, timestamp: 1.0)), .first)
        try expectEqual(probe.observe(frame(source: 11, timestamp: 1.1)), .replay)
        try expectEqual(probe.observe(frame(source: 10, timestamp: 1.0)), .replay)
        try expectEqual(probe.observe(frame(source: 11, timestamp: 1.1)), .replay)
        try expectEqual(probe.observe(frame(source: 10, timestamp: 1.0)), .replay)
    }

    await t.test("MultitouchRecoveryFrameFilter: 새 service 첫 neutral frame은 즉시 release") {
        var filter = MultitouchRecoveryFrameFilter()
        var gate = FingerCountGate(target: 5, debounce: 0)
        try expectEqual(gate.update(count: 5, now: 0), .down)

        filter.beginTrustedReplacement(serviceID: 20)
        let neutral = frame(source: 100, timestamp: 10, physicalCount: 0)
        try expectEqual(
            filter.observe(neutral, boundServiceID: 10),
            .waitForExpectedReplacement
        )
        try expectEqual(
            filter.observe(neutral, boundServiceID: 20),
            .acceptedReplacement
        )
        try expectEqual(gate.update(count: 0, now: 1), .up)
        try expectEqual(filter.mode, .none)
    }

    await t.test("MultitouchRecoveryFrameFilter: 같은 service는 A/B/C 진행 뒤 판정") {
        var filter = MultitouchRecoveryFrameFilter()
        filter.beginSameServiceProbe()
        try expectEqual(
            filter.observe(frame(source: 10, timestamp: 1.0), boundServiceID: 20),
            .waitForProgress
        )
        try expectEqual(
            filter.observe(frame(source: 11, timestamp: 1.1), boundServiceID: 20),
            .waitForProgress
        )
        try expectEqual(
            filter.observe(frame(source: 10, timestamp: 1.0), boundServiceID: 20),
            .waitForProgress
        )
        try expectEqual(
            filter.observe(frame(source: 11, timestamp: 1.1), boundServiceID: 20),
            .waitForProgress
        )
        try expectEqual(
            filter.observe(frame(source: 12, timestamp: 1.2), boundServiceID: 20),
            .acceptedProgress
        )
        try expectEqual(filter.mode, .none)
    }

    await t.test("MultitouchRecoveryFrameFilter: watchdog가 먼저 새 service를 bind해도 교체로 분류") {
        var filter = MultitouchRecoveryFrameFilter()
        filter.beginSameServiceProbe()
        filter.finishRebind(previousServiceID: 10, boundServiceID: 20)
        try expectEqual(filter.mode, .trustedReplacement(serviceID: 20))
        try expectEqual(
            filter.observe(
                frame(source: 100, timestamp: 10, physicalCount: 0),
                boundServiceID: 20
            ),
            .acceptedReplacement
        )

        filter.finishRebind(previousServiceID: 20, boundServiceID: 20)
        try expectEqual(filter.mode, .probingSameService)
    }

    await t.test("MultitouchServiceIdentity: registry 교체와 다른 물리 장치를 구분") {
        let old = serviceIdentity(registryID: 10, multitouchID: 100, serial: "A")
        let replacement = serviceIdentity(registryID: 20, multitouchID: 100, serial: "A")
        let other = serviceIdentity(registryID: 30, multitouchID: 200, serial: "A")
        try expect(old.isSamePhysicalDevice(as: replacement))
        try expect(!old.isSamePhysicalDevice(as: other))

        let serialFallback = serviceIdentity(
            registryID: 40, multitouchID: nil, serial: "A"
        )
        let serialReplacement = serviceIdentity(
            registryID: 50, multitouchID: nil, serial: "A"
        )
        try expect(serialFallback.isSamePhysicalDevice(as: serialReplacement))

        let incompleteBuiltIn = serviceIdentity(
            registryID: 60,
            multitouchID: nil,
            serial: nil,
            transport: nil,
            builtIn: true,
            vendorID: nil,
            productID: nil,
            familyID: nil,
            locationID: nil
        )
        let anotherIncompleteBuiltIn = serviceIdentity(
            registryID: 70,
            multitouchID: nil,
            serial: nil,
            transport: nil,
            builtIn: true,
            vendorID: nil,
            productID: nil,
            familyID: nil,
            locationID: nil
        )
        try expect(!incompleteBuiltIn.isSamePhysicalDevice(as: anotherIncompleteBuiltIn))
    }

    await t.test("MultitouchServiceTopology: new-before-old와 중복 notification을 멱등 처리") {
        let old = serviceIdentity(registryID: 10, multitouchID: 100, serial: "A")
        let replacement = serviceIdentity(registryID: 20, multitouchID: 100, serial: "A")
        var topology = MultitouchServiceTopology()
        topology.seed([old])

        try expectEqual(topology.appeared(old), false)
        try expectEqual(topology.appeared(replacement), true)
        try expectEqual(topology.appeared(replacement), false)
        try expectEqual(topology.serviceIDs, Set([10, 20]))
        try expectEqual(topology.disappeared(10), old)
        try expectEqual(topology.disappeared(10), nil)
        try expectEqual(topology.serviceIDs, Set([20]))
    }

    await t.test("MultitouchPowerTransition: suspend/resume 쌍당 한 번만 복구") {
        var transition = MultitouchPowerTransition()
        try expectEqual(transition.observe(.resumed), false)
        try expectEqual(transition.observe(.suspended), false)
        try expectEqual(transition.observe(.willPowerOff), false)
        try expectEqual(transition.observe(.poweredOn), true)
        try expectEqual(transition.observe(.resumed), false)
        try expectEqual(transition.isPending, false)
    }

    await t.test("MultitouchWatchdog: callback silence면 device 복구") {
        let watchdog = MultitouchWatchdog(stallTimeout: 1.5)
        let heartbeat = MultitouchHeartbeat(now: 10.0)
        try expectEqual(
            watchdog.evaluate(
                engaged: true, recoveringDevice: false,
                now: 11.5, heartbeat: heartbeat
            ),
            .recoverDevice(.callbackSilent)
        )
    }

    await t.test("MultitouchWatchdog: callback replay로 source가 멎으면 device 복구") {
        let watchdog = MultitouchWatchdog(stallTimeout: 1.5)
        var heartbeat = MultitouchHeartbeat(now: 10.0)
        let stale = frame(source: 20, timestamp: 5.0)
        heartbeat.observe(stale, receivedAt: 10.0)
        heartbeat.observe(stale, receivedAt: 11.6) // callback만 계속 도착
        try expectEqual(
            watchdog.evaluate(
                engaged: true, recoveringDevice: false,
                now: 11.6, heartbeat: heartbeat
            ),
            .recoverDevice(.sourceFrozen)
        )
    }

    await t.test("MultitouchWatchdog: source는 진행해도 touch record가 멎으면 device 복구") {
        let watchdog = MultitouchWatchdog(stallTimeout: 1.5)
        var heartbeat = MultitouchHeartbeat(now: 10.0)
        heartbeat.observe(
            frame(source: 20, timestamp: 5.0, touchFrame: 7),
            receivedAt: 10.0
        )
        heartbeat.observe(
            frame(source: 21, timestamp: 5.1, touchFrame: 7),
            receivedAt: 11.6
        )
        try expectEqual(
            watchdog.evaluate(
                engaged: true, recoveringDevice: false,
                now: 11.6, heartbeat: heartbeat
            ),
            .recoverDevice(.contactFrozen)
        )
    }

    await t.test("MultitouchWatchdog: 재연결 뒤 프레임이 없어도 시간으로 녹음을 끊지 않음") {
        let watchdog = MultitouchWatchdog(stallTimeout: 1.5)
        let heartbeat = MultitouchHeartbeat(now: 100.0)
        try expectEqual(
            watchdog.evaluate(
                engaged: true, recoveringDevice: true,
                now: 101.5, heartbeat: heartbeat
            ),
            .none
        )
    }

    await t.test("MultitouchWatchdog: source가 진행하는 24시간 hold는 정상") {
        let watchdog = MultitouchWatchdog(stallTimeout: 1.5)
        var heartbeat = MultitouchHeartbeat(now: 0)
        heartbeat.observe(
            frame(source: 1_000_000, timestamp: 86_400.0),
            receivedAt: 86_400.0
        )
        try expectEqual(
            watchdog.evaluate(
                engaged: true, recoveringDevice: false,
                now: 86_400.1, heartbeat: heartbeat
            ),
            .none
        )
    }

    await t.test("MultitouchWatchdog: 유휴 상태는 stale이어도 녹음 종료를 만들지 않음") {
        let watchdog = MultitouchWatchdog(stallTimeout: 1.5)
        let heartbeat = MultitouchHeartbeat(now: 0)
        try expectEqual(
            watchdog.evaluate(
                engaged: false, recoveringDevice: false,
                now: 100_000, heartbeat: heartbeat
            ),
            .none
        )
    }
}
