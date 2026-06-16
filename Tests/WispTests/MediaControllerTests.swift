import Foundation
@testable import WispCore

@MainActor
func mediaControllerTests(_ t: TestRunner) async {
    await t.test("Media: 재생 중(probe true)이면 pause(1), 우리가 멈춘 경우만 play(0)") {
        var cmds: [Int] = []
        // probe-first: 먼저 재생 여부를 읽고(여기선 동기 true) 그 결과로 정지/재개를 정한다.
        let mc = MediaController(send: { cmds.append($0) }, probe: { $0(true) })

        // 멈춘 적 없으면 재개는 no-op
        mc.resumeIfPaused()
        try expectEqual(cmds, [])

        mc.pauseMedia()
        try expectEqual(cmds, [1])          // 재생 중 확인 → pause

        mc.resumeIfPaused()
        try expectEqual(cmds, [1, 0])       // play

        // 한 번 재개한 뒤 또 호출해도 no-op (멱등)
        mc.resumeIfPaused()
        try expectEqual(cmds, [1, 0])
    }

    await t.test("Media: 멈춰 있으면(probe false) 아무것도 안 보냄 — 깨우지 않음") {
        var cmds: [Int] = []
        let mc = MediaController(send: { cmds.append($0) }, probe: { $0(false) })

        mc.pauseMedia()
        try expectEqual(cmds, [])           // 이미 멈춤 → 명령 안 보냄(pause조차 불필요)

        mc.resumeIfPaused()
        try expectEqual(cmds, [])           // 멈춰 있던 미디어를 깨우지 않음(보고된 버그 회귀 방지)
    }

    await t.test("Media: 재생 여부 불명(probe nil)이면 낙관적 pause만, 재개 안 함 — 무깨움") {
        var cmds: [Int] = []
        // 읽기 차단(perl 실패 등) → nil. 전역 정지는 살리되(브라우저) 깨우지 않으려 재개는 안 함.
        let mc = MediaController(send: { cmds.append($0) }, probe: { $0(nil) })

        mc.pauseMedia()
        try expectEqual(cmds, [1])          // 불명 → pause(낙관적)

        mc.resumeIfPaused()
        try expectEqual(cmds, [1])          // 불확실 → 재개 안 함
    }

    await t.test("Media: 종료 후 늦게 온 probe는 무시 — 명령도 재개도 안 일어남") {
        var cmds: [Int] = []
        var late: ((Bool?) -> Void)?
        // probe 완료를 보류했다가 나중에 수동 발화 → "종료 후 늦은 probe(재생 중 판정)" 재현
        let mc = MediaController(send: { cmds.append($0) }, probe: { late = $0 })

        mc.pauseMedia()                     // probe 보류 — 아직 아무 명령도 안 보냄(probe-first)
        try expectEqual(cmds, [])
        mc.resumeIfPaused()                 // 종료 → generation 무효화
        try expectEqual(cmds, [])

        late?(true)                         // 뒤늦게 "재생 중"이 와도 generation 불일치로 무시
        mc.resumeIfPaused()
        try expectEqual(cmds, [])           // pause도 재개도 안 일어남
    }
}
