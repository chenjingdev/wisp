import Foundation
@testable import WispCore

private func makeRecord(id: String, createdAt: Date,
                        transcript: String? = "안녕하세요",
                        llmOutput: String? = "Hello") -> DictationRecord {
    DictationRecord(
        id: id,
        createdAt: createdAt,
        transcript: transcript,
        llmOutput: llmOutput,
        modeId: "dictation",
        targetBundleId: nil,
        llmSucceeded: true,
        recordSeconds: 1.0,
        sttSeconds: 0.5,
        llmSeconds: 0.3
    )
}

@MainActor
func historyStoreTests(_ t: TestRunner) async {
    await t.test("History: 저장 후 최신 조회") {
        let store = try HistoryStore(inMemory: true)
        let t100 = Date(timeIntervalSince1970: 100)
        let t200 = Date(timeIntervalSince1970: 200)
        try store.save(makeRecord(id: "a", createdAt: t100))
        try store.save(makeRecord(id: "b", createdAt: t200))
        let latest = try store.fetchLatest()
        try expectEqual(try unwrap(latest).id, "b")
    }

    await t.test("History: 빈 DB는 nil") {
        let store = try HistoryStore(inMemory: true)
        let latest = try store.fetchLatest()
        try expectEqual(latest, nil)
    }

    await t.test("History: 실패 기록 (llmOutput nil)") {
        let store = try HistoryStore(inMemory: true)
        var record = makeRecord(id: "c", createdAt: Date(timeIntervalSince1970: 300))
        record.llmOutput = nil
        record.llmSucceeded = false
        try store.save(record)
        let fetched = try unwrap(try store.fetchLatest())
        try expectEqual(fetched.id, "c")
        try expectEqual(fetched.llmOutput, nil)
        try expectEqual(fetched.llmSucceeded, false)
    }

    await t.test("History: fetchPage 검색·페이지네이션") {
        let store = try HistoryStore(inMemory: true)
        let base = Date(timeIntervalSince1970: 1000)
        for i in 0..<5 {
            try store.save(makeRecord(
                id: "r\(i)", createdAt: base.addingTimeInterval(Double(i)),
                transcript: i == 2 ? "회의 일정 공유" : "일반 텍스트 \(i)",
                llmOutput: i == 4 ? "회의록 정리" : nil
            ))
        }

        // 전체 — 최신순
        let all = try store.fetchPage(query: nil, before: nil, limit: 10)
        try expectEqual(all.map(\.id), ["r4", "r3", "r2", "r1", "r0"])

        // 페이지네이션 — r3보다 오래된 것 2개
        let page2 = try store.fetchPage(query: nil, before: all[1].createdAt, limit: 2)
        try expectEqual(page2.map(\.id), ["r2", "r1"])

        // 검색 — transcript와 llmOutput 모두 대상
        let hits = try store.fetchPage(query: "회의", before: nil, limit: 10)
        try expectEqual(Set(hits.map(\.id)), Set(["r2", "r4"]))
    }

    await t.test("History: 검색어의 LIKE 메타문자(%/_)는 리터럴로 매칭") {
        let store = try HistoryStore(inMemory: true)
        let base = Date(timeIntervalSince1970: 5000)
        try store.save(makeRecord(id: "p", createdAt: base, transcript: "50% 할인", llmOutput: nil))
        try store.save(makeRecord(id: "q", createdAt: base.addingTimeInterval(1),
                                  transcript: "five zero percent", llmOutput: nil))
        try store.save(makeRecord(id: "u", createdAt: base.addingTimeInterval(2),
                                  transcript: "a_b 표기", llmOutput: nil))
        try store.save(makeRecord(id: "x", createdAt: base.addingTimeInterval(3),
                                  transcript: "axb 표기", llmOutput: nil))

        // "50%"는 와일드카드가 아니라 리터럴 — q는 매칭되면 안 됨
        try expectEqual(try store.fetchPage(query: "50%", before: nil, limit: 10).map(\.id), ["p"])
        // "a_b"의 _는 임의 1문자가 아니라 리터럴 — x(axb)는 매칭되면 안 됨
        try expectEqual(try store.fetchPage(query: "a_b", before: nil, limit: 10).map(\.id), ["u"])
    }

    await t.test("History: delete는 행 제거(없는 id 무시), purge는 오래된 행 일괄 삭제") {
        let store = try HistoryStore(inMemory: true)
        let base = Date(timeIntervalSince1970: 1000)
        try store.save(makeRecord(id: "old", createdAt: base))
        try store.save(makeRecord(id: "new", createdAt: base.addingTimeInterval(100)))

        try store.delete(id: "new")
        try expectEqual(try store.fetchPage(query: nil, before: nil, limit: 10).map(\.id), ["old"])
        try store.delete(id: "없는id")   // 없는 id는 조용히 무시
        try expectEqual(try store.fetchPage(query: nil, before: nil, limit: 10).count, 1)

        try store.purge(olderThan: base.addingTimeInterval(50))
        try expectEqual(try store.fetchPage(query: nil, before: nil, limit: 10).count, 0)
    }
}
