import Foundation
import GRDB

struct GRDBCaptureStore: CaptureStoring {
    let database: AppDatabase
    private let makeID: @Sendable () -> String

    init(database: AppDatabase, makeID: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.database = database
        self.makeID = makeID
    }

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

    func registerDiscovered(_ screenshots: [DiscoveredScreenshot]) async throws -> ScreenshotSyncResult {
        let makeID = self.makeID
        return try await database.dbWriter.write { db in
            var known: [String: CaptureAvailability] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT photoAssetID, availability FROM capture") {
                let assetID: String = row["photoAssetID"]
                let raw: String = row["availability"]
                known[assetID] = CaptureAvailability(rawValue: raw)
            }

            var registered = 0
            var restored = 0
            for shot in screenshots {
                switch known[shot.assetID] {
                case nil:
                    try Capture(
                        id: makeID(),
                        photoAssetID: shot.assetID,
                        capturedAt: shot.capturedAt,
                        width: shot.width,
                        height: shot.height,
                        availability: .accessible,
                        excludedAt: nil,
                        favorite: false,
                        contentRevision: 1,
                        searchState: .pending,
                        classificationState: .pending
                    ).insert(db)
                    known[shot.assetID] = .accessible
                    registered += 1
                case .unavailable?:
                    try db.execute(
                        sql: "UPDATE capture SET availability = 'accessible' WHERE photoAssetID = ?",
                        arguments: [shot.assetID]
                    )
                    known[shot.assetID] = .accessible
                    restored += 1
                case .accessible?:
                    break
                }
            }

            let discovered = Set(screenshots.map(\.assetID))
            var becameUnavailable = 0
            for (assetID, availability) in known where availability == .accessible && !discovered.contains(assetID) {
                try db.execute(
                    sql: "UPDATE capture SET availability = 'unavailable' WHERE photoAssetID = ?",
                    arguments: [assetID]
                )
                becameUnavailable += 1
            }

            return ScreenshotSyncResult(
                registered: registered,
                restored: restored,
                becameUnavailable: becameUnavailable
            )
        }
    }

    func saveAnalysis(_ analysis: CaptureAnalysis, searchDocument: SearchDocument) async throws {
        try await database.dbWriter.write { db in
            try analysis.save(db)
            try searchDocument.save(db)
            try db.execute(
                sql: "UPDATE capture SET searchState = 'ready' WHERE id = ?",
                arguments: [analysis.captureID]
            )
        }
    }

    func nextPendingForAnalysis() async throws -> Capture? {
        try await database.dbWriter.read { db in
            try Capture.fetchOne(db, sql: """
                SELECT * FROM capture
                WHERE \(Self.visible)
                  AND capture.searchState = 'pending'
                ORDER BY capturedAt DESC
                LIMIT 1
                """)
        }
    }

    func markSearchProcessing(_ captureID: String) async throws {
        try await database.dbWriter.write { db in
            try db.execute(sql: "UPDATE capture SET searchState = 'processing' WHERE id = ?", arguments: [captureID])
        }
    }

    func markSearchFailed(_ captureID: String) async throws {
        try await database.dbWriter.write { db in
            try db.execute(sql: "UPDATE capture SET searchState = 'failed' WHERE id = ?", arguments: [captureID])
        }
    }

    func resetStuckProcessing() async throws {
        try await database.dbWriter.write { db in
            try db.execute(sql: "UPDATE capture SET searchState = 'pending' WHERE searchState = 'processing'")
        }
    }

    func fetchSearchCandidates(capturedFrom: Date?, capturedBefore: Date?) async throws -> [SearchCandidate] {
        try await database.dbWriter.read { db in
            var sql = """
                SELECT capture.*, captureAnalysis.ocrText AS ocrText, searchDocument.searchText AS searchText,
                       searchDocument.embedding AS embedding
                FROM capture
                JOIN captureAnalysis ON captureAnalysis.captureID = capture.id
                JOIN searchDocument ON searchDocument.captureID = capture.id
                WHERE \(Self.visible)
                """
            var arguments: [any DatabaseValueConvertible] = []
            if let capturedFrom {
                sql += " AND capture.capturedAt >= ?"
                arguments.append(capturedFrom)
            }
            if let capturedBefore {
                sql += " AND capture.capturedAt < ?"
                arguments.append(capturedBefore)
            }
            sql += " ORDER BY capture.capturedAt DESC"

            let rows = try SearchCandidateRow.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            return rows.map(\.asSearchCandidate)
        }
    }

    func currentEmbeddingModelVersion() async throws -> String? {
        try await database.dbWriter.read { db in
            try String.fetchOne(db, sql: "SELECT embeddingModelVersion FROM searchDocument LIMIT 1")
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

// fetchSearchCandidates()의 3-way join 결과 하나를 그대로 받는 전용 레코드. Capture 자체를
// 재사용하지 않는 이유: capture.* 만으로는 ocrText/searchText/embedding까지 같이 못 실어서,
// Codable 자동 디코딩(embedding의 JSON 텍스트 -> [Double] 변환 포함, SearchDocument와 동일한
// GRDB 메커니즘)을 그대로 쓸 수 있는 별도 구조체를 둔다.
private struct SearchCandidateRow: Decodable, FetchableRecord {
    let id: String
    let photoAssetID: String
    let capturedAt: Date
    let width: Int
    let height: Int
    let availability: CaptureAvailability
    let excludedAt: Date?
    let favorite: Bool
    let contentRevision: Int
    let searchState: SearchState
    let classificationState: ClassificationState
    let ocrText: String?
    let searchText: String
    let embedding: [Double]

    var asSearchCandidate: SearchCandidate {
        SearchCandidate(
            capture: Capture(
                id: id, photoAssetID: photoAssetID, capturedAt: capturedAt, width: width, height: height,
                availability: availability, excludedAt: excludedAt, favorite: favorite,
                contentRevision: contentRevision, searchState: searchState, classificationState: classificationState
            ),
            ocrText: ocrText, searchText: searchText, embedding: embedding
        )
    }
}
