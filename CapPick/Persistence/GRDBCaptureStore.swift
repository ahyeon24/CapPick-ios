import GRDB

struct GRDBCaptureStore: CaptureStoring {
    let database: AppDatabase

    private static let visible = "capture.availability = 'accessible' AND capture.excludedAt IS NULL"

    func save(_ capture: Capture) async throws {
        try await database.dbWriter.write { db in
            try capture.save(db)
        }
    }

    func fetchAll() async throws -> [Capture] {
        try await database.dbWriter.read { db in
            try Capture.fetchAll(db, sql: """
                SELECT * FROM capture
                WHERE \(Self.visible)
                ORDER BY capturedAt DESC
                """)
        }
    }

    func fetchUnclassified() async throws -> [Capture] {
        try await database.dbWriter.read { db in
            try Capture.fetchAll(db, sql: """
                SELECT * FROM capture
                WHERE \(Self.visible)
                  AND capture.searchState = 'ready'
                  AND capture.classificationState = 'complete'
                  AND NOT EXISTS (
                    SELECT 1 FROM folderCapture
                    WHERE folderCapture.captureID = capture.id AND folderCapture.state = 'present'
                  )
                ORDER BY capturedAt DESC
                """)
        }
    }

    func fetch(in folder: Folder) async throws -> [Capture] {
        let folderID = folder.id
        return try await database.dbWriter.read { db in
            try Capture.fetchAll(db, sql: """
                SELECT capture.* FROM capture
                JOIN folderCapture ON folderCapture.captureID = capture.id
                WHERE folderCapture.folderID = ? AND folderCapture.state = 'present'
                  AND \(Self.visible)
                ORDER BY capture.capturedAt DESC
                """, arguments: [folderID])
        }
    }

    func currentProgress() async throws -> AnalysisProgress {
        try await database.dbWriter.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT
                  COUNT(*) AS total,
                  COALESCE(SUM(searchState = 'ready'), 0) AS searchReady,
                  COALESCE(SUM(searchState IN ('pending', 'processing')), 0) AS searchPending,
                  COALESCE(SUM(searchState = 'failed'), 0) AS searchFailed,
                  COALESCE(SUM(searchState = 'ready' AND classificationState IN ('pending', 'processing')), 0) AS classificationPending,
                  COALESCE(SUM(searchState = 'ready' AND classificationState = 'failed'), 0) AS classificationFailed
                FROM capture
                WHERE \(Self.visible)
                """)
            guard let row else {
                return AnalysisProgress(
                    total: 0, searchReady: 0, searchPending: 0, searchFailed: 0,
                    classificationPending: 0, classificationFailed: 0
                )
            }
            return AnalysisProgress(
                total: row["total"],
                searchReady: row["searchReady"],
                searchPending: row["searchPending"],
                searchFailed: row["searchFailed"],
                classificationPending: row["classificationPending"],
                classificationFailed: row["classificationFailed"]
            )
        }
    }
}
