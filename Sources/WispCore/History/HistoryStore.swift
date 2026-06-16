import Foundation
import GRDB

struct DictationRecord: Codable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "dictation"

    var id: String
    var createdAt: Date
    var transcript: String?
    var llmOutput: String?
    var modeId: String
    var targetBundleId: String?
    var llmSucceeded: Bool
    var recordSeconds: Double
    var sttSeconds: Double
    var llmSeconds: Double
}

final class HistoryStore: HistoryStoring {
    private let dbQueue: DatabaseQueue

    init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try migrate()
    }

    init(inMemory: Bool) throws {
        precondition(inMemory)
        dbQueue = try DatabaseQueue()
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "dictation") { t in
                t.column("id", .text).primaryKey()
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("wavPath", .text).notNull()
                t.column("transcript", .text)
                t.column("llmOutput", .text)
                t.column("modeId", .text).notNull()
                t.column("targetBundleId", .text)
                t.column("llmSucceeded", .boolean).notNull()
                t.column("recordSeconds", .double).notNull()
                t.column("sttSeconds", .double).notNull()
                t.column("llmSeconds", .double).notNull()
            }
        }
        // v2: 녹음 wav 저장/재생 기능 제거 — 더는 쓰지 않는 wavPath 컬럼을 떼어낸다.
        // (행은 보존, 해당 컬럼만 삭제. SQLite 3.35+ DROP COLUMN)
        migrator.registerMigration("v2-drop-wavPath") { db in
            try db.execute(sql: "ALTER TABLE dictation DROP COLUMN wavPath")
        }
        try migrator.migrate(dbQueue)
    }

    func save(_ record: DictationRecord) throws {
        try dbQueue.write { try record.insert($0) }
    }

    func fetchLatest() throws -> DictationRecord? {
        try dbQueue.read {
            try DictationRecord.order(Column("createdAt").desc).fetchOne($0)
        }
    }

    func fetchPage(query: String?, before: Date?, limit: Int) throws -> [DictationRecord] {
        try dbQueue.read { db in
            var request = DictationRecord.all()
            if let query, !query.isEmpty {
                // 사용자 입력의 LIKE 메타문자(% _ \)를 리터럴로 처리 — 이스케이프 후
                // ESCAPE 절 지정. 역슬래시를 가장 먼저 치환해야 이중 이스케이프를 막는다.
                let escaped = query
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                let pattern = "%\(escaped)%"
                request = request.filter(
                    Column("transcript").like(pattern, escape: "\\")
                    || Column("llmOutput").like(pattern, escape: "\\")
                )
            }
            if let before {
                request = request.filter(Column("createdAt") < before)
            }
            // createdAt 보조키로 id를 더해 동률 시에도 순서를 결정적으로 만든다.
            // (커서는 createdAt만 쓰므로, 동일 밀리초 다중 행이 페이지 경계에 걸리면
            //  이론상 경계 행을 건너뛸 수 있다 — 사람 발화 간격상 실사용에선 도달 불가.)
            return try request
                .order(Column("createdAt").desc, Column("id").desc)
                .limit(limit).fetchAll(db)
        }
    }

    func delete(id: String) throws {
        _ = try dbQueue.write { db in
            try DictationRecord.deleteOne(db, key: id)
        }
    }

    func purge(olderThan date: Date) throws {
        _ = try dbQueue.write { db in
            try DictationRecord.filter(Column("createdAt") < date).deleteAll(db)
        }
    }
}
