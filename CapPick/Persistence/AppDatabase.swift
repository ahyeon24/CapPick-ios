import Foundation
import GRDB

// 로컬 DB가 캡처·폴더·검색 정보의 기준 저장소다 (시스템 설계 §3). 컬럼 이름은 Models의
// Swift 프로퍼티 이름(camelCase)을 그대로 쓴다 — ERD §2는 논리 설계라 물리 이름은 미확정.
struct AppDatabase: Sendable {
    let dbWriter: any DatabaseWriter

    init(_ dbWriter: any DatabaseWriter) throws {
        self.dbWriter = dbWriter
        try Self.migrator.migrate(dbWriter)
    }

    static func makeInMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    static func makeOnDisk() throws -> AppDatabase {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let path = directory.appendingPathComponent("cappick.sqlite").path
        return try AppDatabase(DatabasePool(path: path))
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "capture") { t in
                t.primaryKey("id", .text)
                t.column("photoAssetID", .text).notNull().unique()
                t.column("capturedAt", .datetime).notNull()
                t.column("width", .integer).notNull()
                t.column("height", .integer).notNull()
                t.column("availability", .text).notNull()
                t.column("excludedAt", .datetime)
                t.column("favorite", .boolean).notNull()
                t.column("contentRevision", .integer).notNull()
                t.column("searchState", .text).notNull()
                t.column("classificationState", .text).notNull()
            }
            try db.create(index: "capture_on_capturedAt", on: "capture", columns: ["capturedAt"])
            try db.create(index: "capture_on_searchState", on: "capture", columns: ["searchState"])

            try db.create(table: "captureAnalysis") { t in
                t.primaryKey("captureID", .text).references("capture", onDelete: .cascade)
                t.column("contentRevision", .integer).notNull()
                t.column("analysisRevision", .integer).notNull()
                t.column("ocrText", .text)
                t.column("observedEvidence", .text).notNull()
                t.column("modelVersion", .text).notNull()
            }

            try db.create(table: "searchDocument") { t in
                t.primaryKey("captureID", .text).references("capture", onDelete: .cascade)
                t.column("sourceAnalysisRevision", .integer).notNull()
                t.column("searchText", .text).notNull()
                // 벡터는 JSON 텍스트로 저장 — 저장 방식은 시스템 설계 §9상 미정. 수천 장 성능 검증 후 교체 가능.
                t.column("embedding", .text).notNull()
                t.column("embeddingModelVersion", .text).notNull()
                t.column("state", .text).notNull()
            }

            try db.create(table: "folder") { t in
                t.primaryKey("id", .text)
                t.column("displayName", .text).notNull()
                t.column("criteriaText", .text)
                t.column("criteriaVersion", .integer).notNull()
                t.column("criteriaState", .text).notNull()
                t.column("membershipRevision", .integer).notNull()
            }

            try db.create(table: "folderCapture") { t in
                t.column("folderID", .text).notNull().references("folder", onDelete: .cascade)
                t.column("captureID", .text).notNull().references("capture", onDelete: .cascade)
                t.column("state", .text).notNull()
                t.column("source", .text).notNull()
                t.column("evidence", .text)
                t.column("criteriaVersion", .integer).notNull()
                t.column("revision", .integer).notNull()
                t.primaryKey(["folderID", "captureID"])
            }
            try db.create(index: "folderCapture_on_captureID", on: "folderCapture", columns: ["captureID"])

            try db.create(table: "localTask") { t in
                t.primaryKey("id", .text)
                t.column("captureID", .text).references("capture", onDelete: .cascade)
                t.column("folderID", .text).references("folder", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("inputRevision", .integer).notNull()
                t.column("criteriaVersion", .integer)
                t.column("serverJobID", .text)
                t.column("idempotencyKey", .text).notNull().unique()
                t.column("state", .text).notNull()
                t.column("attempts", .integer).notNull()
                t.column("errorCode", .text)
                t.column("nextRetryAt", .datetime)
            }

            try db.create(table: "reclassificationRun") { t in
                t.primaryKey("id", .text)
                t.column("folderID", .text).notNull().references("folder", onDelete: .cascade)
                t.column("criteriaVersion", .integer).notNull()
                t.column("membershipRevision", .integer).notNull()
                t.column("mode", .text).notNull()
                t.column("state", .text).notNull()
            }

            try db.create(table: "reclassificationItem") { t in
                t.column("runID", .text).notNull().references("reclassificationRun", onDelete: .cascade)
                t.column("captureID", .text).notNull().references("capture", onDelete: .cascade)
                t.column("action", .text).notNull()
                t.column("evidence", .text)
                t.column("expectedMembershipRevision", .integer)
                t.column("state", .text).notNull()
                t.primaryKey(["runID", "captureID"])
            }

            try db.create(table: "appState") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }

        // 재시도마다 다른 Idempotency-Key를 만들기 위한 카운터(ContentAnalysisService 참고).
        // 기존 행은 전부 0으로 채워진다(SQLite ALTER TABLE ADD COLUMN의 DEFAULT가 즉시 backfill).
        migrator.registerMigration("v2") { db in
            try db.alter(table: "capture") { t in
                t.add(column: "analysisAttempt", .integer).notNull().defaults(to: 0)
            }
        }

        return migrator
    }
}
