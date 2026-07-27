import Foundation

/// `MultitouchSupport.framework`가 콜백으로 넘기는 한 프레임을, Swift가 소유하는 값으로
/// 즉시 복사한 결과. 원본 `touches` 포인터는 콜백이 반환되면 더 이상 유효하지 않다.
///
/// `reportedCount`는 실제 접촉 수가 아니라 hover/release/linger를 포함한 path 레코드 수다.
/// 현재 macOS 26.5의 `MTTouch` ABI(96-byte stride)를 검증한 뒤 MakeTouch(3)와
/// Touching(4)만 `physicalCount`로 센다. ABI 검증에 실패하면 안전하게 reportedCount로
/// 폴백하고, source frame heartbeat만 사용한다.
struct MultitouchFrame: Equatable {
    let reportedCount: Int
    let physicalCount: Int
    let sourceTimestamp: TimeInterval
    let sourceFrame: Int32
    let newestPhysicalTouchFrame: Int32?
    let stateCounts: [Int]
    let touchLayoutValid: Bool

    var stateSummary: String {
        guard touchLayoutValid else { return "layout=fallback raw=\(reportedCount)" }
        return "raw=\(reportedCount) physical=\(physicalCount) states=\(stateCounts)"
    }
}

enum MultitouchFrameDecoder {
    // OpenMultitouchSupport의 역공학 헤더와 이 머신의 macOS 26.5 바이너리/실기 프로브로
    // 확인한 MTTouch layout. 각 레코드의 frame이 callback sourceFrame과 같은지도 매
    // 프레임 검증하므로, 향후 ABI가 달라지면 state 기반 판정을 사용하지 않는다.
    static let maximumTouchCount = 32
    static let touchStride = 96
    static let frameOffset = 0
    static let stateOffset = 20

    static func decode(touches: UnsafeMutableRawPointer?,
                       reportedCount: Int,
                       sourceTimestamp: TimeInterval,
                       sourceFrame: Int32) -> MultitouchFrame {
        let count = max(0, reportedCount)
        guard count > 0 else {
            return MultitouchFrame(
                reportedCount: 0, physicalCount: 0,
                sourceTimestamp: sourceTimestamp, sourceFrame: sourceFrame,
                newestPhysicalTouchFrame: nil,
                stateCounts: Array(repeating: 0, count: 8),
                touchLayoutValid: true
            )
        }

        guard count <= maximumTouchCount, let touches else {
            return fallback(count: count, timestamp: sourceTimestamp, frame: sourceFrame)
        }

        var states = Array(repeating: 0, count: 8)
        var physicalCount = 0
        var newestPhysicalFrame: Int32?
        var layoutValid = true

        for index in 0..<count {
            let base = index * touchStride
            let touchFrame = touches.load(fromByteOffset: base + frameOffset, as: Int32.self)
            let state = touches.load(fromByteOffset: base + stateOffset, as: Int32.self)

            guard (0...7).contains(state), touchFrame == sourceFrame else {
                layoutValid = false
                break
            }

            states[Int(state)] += 1
            if state == 3 || state == 4 { // MakeTouch / Touching
                physicalCount += 1
                if newestPhysicalFrame == nil || touchFrame != newestPhysicalFrame {
                    newestPhysicalFrame = touchFrame
                }
            }
        }

        guard layoutValid else {
            return fallback(count: count, timestamp: sourceTimestamp, frame: sourceFrame)
        }
        return MultitouchFrame(
            reportedCount: count, physicalCount: physicalCount,
            sourceTimestamp: sourceTimestamp, sourceFrame: sourceFrame,
            newestPhysicalTouchFrame: newestPhysicalFrame,
            stateCounts: states, touchLayoutValid: true
        )
    }

    private static func fallback(count: Int,
                                 timestamp: TimeInterval,
                                 frame: Int32) -> MultitouchFrame {
        MultitouchFrame(
            reportedCount: count, physicalCount: count,
            sourceTimestamp: timestamp, sourceFrame: frame,
            newestPhysicalTouchFrame: nil,
            stateCounts: [],
            touchLayoutValid: false
        )
    }
}

/// 콜백 도착과 source 데이터의 실제 진행을 분리해서 기록한다.
///
/// 예전 구현은 main queue에서 오래된 프레임을 소비한 시각을 `lastFrameAt`으로 써서,
/// backlog에 쌓인 동일 프레임도 새 데이터처럼 보일 수 있었다. 이제 callback 수신 시각과
/// `(sourceFrame, sourceTimestamp)`, per-touch frame의 진척을 각각 추적한다.
struct MultitouchHeartbeat: Equatable {
    private(set) var lastCallbackAt: TimeInterval
    private(set) var lastSourceProgressAt: TimeInterval
    private(set) var lastContactProgressAt: TimeInterval

    private var lastSourceFrame: Int32?
    private var lastSourceTimestamp: TimeInterval?
    private var lastPhysicalTouchFrame: Int32?

    init(now: TimeInterval = 0) {
        lastCallbackAt = now
        lastSourceProgressAt = now
        lastContactProgressAt = now
    }

    mutating func reset(at now: TimeInterval) {
        self = MultitouchHeartbeat(now: now)
    }

    mutating func observe(_ frame: MultitouchFrame, receivedAt: TimeInterval) {
        lastCallbackAt = max(lastCallbackAt, receivedAt)

        // 단순 `!=`는 A/B 두 stale snapshot이 번갈아 replay될 때도 계속 진행한다고
        // 오인한다. device가 바뀔 때는 heartbeat 자체를 reset하므로, 한 device 안에서는
        // 단조 증가하는 source timestamp만 진척으로 인정한다.
        if lastSourceTimestamp == nil ||
            frame.sourceTimestamp > (lastSourceTimestamp ?? -.infinity) {
            lastSourceFrame = frame.sourceFrame
            lastSourceTimestamp = frame.sourceTimestamp
            lastSourceProgressAt = max(lastSourceProgressAt, receivedAt)
        }

        guard frame.touchLayoutValid else {
            // ABI 폴백에서는 per-touch freshness를 판정할 수 없다. source heartbeat가
            // 담당하고 contact heartbeat는 오탐하지 않게 callback과 함께 갱신한다.
            lastContactProgressAt = max(lastContactProgressAt, receivedAt)
            return
        }

        if let touchFrame = frame.newestPhysicalTouchFrame {
            if touchFrame != lastPhysicalTouchFrame {
                lastPhysicalTouchFrame = touchFrame
                lastContactProgressAt = max(lastContactProgressAt, receivedAt)
            }
        } else {
            // 실제 접촉이 없는 프레임도 신선한 release 증거다.
            lastPhysicalTouchFrame = nil
            lastContactProgressAt = max(lastContactProgressAt, receivedAt)
        }
    }
}

/// device 재연결 직후 한 번 도착한 stale snapshot을 정상 복구로 오인하지 않게 한다.
/// 서로 다른 source identity가 연속 두 번 관측돼야 새 스트림이 실제로 진행한다고 본다.
struct MultitouchRecoveryProbe {
    enum Observation: Equatable {
        case first
        case replay
        case progressing
    }

    private struct SourceIdentity: Equatable {
        let frame: Int32
        let timestamp: TimeInterval
    }

    private var firstIdentity: SourceIdentity?

    mutating func reset() {
        firstIdentity = nil
    }

    mutating func observe(_ frame: MultitouchFrame) -> Observation {
        let identity = SourceIdentity(frame: frame.sourceFrame, timestamp: frame.sourceTimestamp)
        guard let firstIdentity else {
            self.firstIdentity = identity
            return .first
        }
        // 다른 값이라는 것만으로는 A/B replay를 배제할 수 없다. source timestamp가
        // 실제로 앞으로 간 경우에만 새 스트림으로 확정한다.
        guard identity.timestamp > firstIdentity.timestamp else { return .replay }
        self.firstIdentity = nil
        return .progressing
    }
}
