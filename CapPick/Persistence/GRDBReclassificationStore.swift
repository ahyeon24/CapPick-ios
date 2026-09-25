import Foundation
import GRDB

struct GRDBReclassificationStore: ReclassificationStoring {
    let database: AppDatabase
    private let makeID: @Sendable () -> String

    init(database: AppDatabase, makeID: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.database = database
        self.makeID = makeID
    }

    func activeRun(folderID: String) async throws -> ReclassificationRun? {
        try await database.dbWriter.read { db in
            try ReclassificationRun.fetchOne(db, sql: """
                SELECT * FROM reclassificationRun
                WHERE folderID = ? AND state = ?
                ORDER BY id DESC LIMIT 1
                """, arguments: [folderID, ReclassificationRunState.previewing])
        }
    }

    func createRun(folderID: String, criteriaVersion: Int, membershipRevision: Int, mode: ReclassificationMode) async throws -> ReclassificationRun {
        let run = ReclassificationRun(
            id: makeID(), folderID: folderID, criteriaVersion: criteriaVersion,
            membershipRevision: membershipRevision, mode: mode, state: ReclassificationRunState.previewing)
        try await database.dbWriter.write { db in
            try run.insert(db)
        }
        return run
    }

    func fetchRun(id: String) async throws -> ReclassificationRun? {
        try await database.dbWriter.read { db in
            try ReclassificationRun.fetchOne(db, key: id)
        }
    }

    func fetchItems(runID: String) async throws -> [ReclassificationItem] {
        try await database.dbWriter.read { db in
            try ReclassificationItem
                .filter(Column("runID") == runID)
                .fetchAll(db)
        }
    }

    func saveItems(_ items: [ReclassificationItem]) async throws {
        try await database.dbWriter.write { db in
            for item in items {
                try item.insert(db)
            }
        }
    }

    func setRunState(_ runID: String, state: String) async throws {
        try await database.dbWriter.write { db in
            try db.execute(sql: "UPDATE reclassificationRun SET state = ? WHERE id = ?", arguments: [state, runID])
        }
    }

    func setItemState(runID: String, captureID: String, state: String) async throws {
        try await database.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE reclassificationItem SET state = ? WHERE runID = ? AND captureID = ?",
                arguments: [state, runID, captureID])
        }
    }
}
