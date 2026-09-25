import GRDB

struct GRDBFolderStore: FolderStoring {
    let database: AppDatabase

    func save(_ folder: Folder) async throws {
        try await database.dbWriter.write { db in
            var toSave = folder
            if let existing = try Folder.fetchOne(db, key: folder.id) {
                toSave.membershipRevision = existing.membershipRevision
            }
            try toSave.save(db)
        }
    }

    func fetchAll() async throws -> [Folder] {
        try await database.dbWriter.read { db in
            try Folder.fetchAll(db)
        }
    }

    func fetchFolder(id: String) async throws -> Folder? {
        try await database.dbWriter.read { db in
            try Folder.fetchOne(db, key: id)
        }
    }

    func delete(id: String) async throws {
        try await database.dbWriter.write { db in
            _ = try Folder.deleteOne(db, key: id)
        }
    }

    func fetchMemberships(of folderID: String) async throws -> [FolderCapture] {
        try await database.dbWriter.read { db in
            try FolderCapture
                .filter(Column("folderID") == folderID)
                .order(Column("captureID"))
                .fetchAll(db)
        }
    }

    func fetchFolders(containing captureID: String) async throws -> [Folder] {
        try await database.dbWriter.read { db in
            try Folder.fetchAll(db, sql: """
                SELECT folder.* FROM folder
                JOIN folderCapture ON folderCapture.folderID = folder.id
                WHERE folderCapture.captureID = ? AND folderCapture.state = 'present'
                """, arguments: [captureID])
        }
    }

    func addManually(captureID: String, to folderID: String) async throws {
        try await database.dbWriter.write { db in
            let folder = try Self.requireFolder(db, folderID)
            _ = try Self.requireCapture(db, captureID)
            try Self.writeMembership(
                db, folder: folder, captureID: captureID,
                state: .present, source: .manual, evidence: nil
            )
        }
    }

    func removeManually(captureID: String, from folderID: String) async throws {
        try await database.dbWriter.write { db in
            let folder = try Self.requireFolder(db, folderID)
            _ = try Self.requireCapture(db, captureID)
            try Self.writeMembership(
                db, folder: folder, captureID: captureID,
                state: .blocked, source: .manual, evidence: nil
            )
        }
    }

    func applyAutoMatch(
        captureID: String,
        to folderID: String,
        evidence: String?,
        criteriaVersion: Int
    ) async throws -> AutoMatchResult {
        try await database.dbWriter.write { db in
            let folder = try Self.requireFolder(db, folderID)
            guard folder.criteriaVersion == criteriaVersion else { return .ignoredStaleCriteria }

            let capture = try Self.requireCapture(db, captureID)
            guard capture.availability == .accessible, capture.excludedAt == nil else {
                return .ignoredCaptureUnavailable
            }

            let key = ["folderID": folderID, "captureID": captureID]
            if let existing = try FolderCapture.fetchOne(db, key: key),
               existing.state == .blocked || existing.source == .manual {
                return .ignoredUserDecision
            }

            try Self.writeMembership(
                db, folder: folder, captureID: captureID,
                state: .present, source: .auto, evidence: evidence
            )
            return .applied
        }
    }

    func applyAutoMismatchRemoval(
        captureID: String,
        from folderID: String,
        criteriaVersion: Int
    ) async throws -> AutoMatchResult {
        try await database.dbWriter.write { db in
            let folder = try Self.requireFolder(db, folderID)
            guard folder.criteriaVersion == criteriaVersion else { return .ignoredStaleCriteria }

            let key = ["folderID": folderID, "captureID": captureID]
            guard let existing = try FolderCapture.fetchOne(db, key: key),
                  existing.state == .present, existing.source == .auto else {
                // 없거나(row 자체가 없음) manual/blocked면 건드리지 않는다 — 직접 소속은 항상 보존.
                return .ignoredUserDecision
            }

            // FolderCapture.state는 present/blocked 두 값뿐이다(ERD §2) — "제거"를 blocked로
            // 표현하면 사용자가 직접 뺀 것과 구분이 안 되고, 향후 진짜 재매치까지 영구히 막아버린다.
            // 그래서 행을 그대로 지운다: 행이 없으면 비소속일 뿐이고, 나중에 applyAutoMatch가
            // 다시 자유롭게 추가할 수 있다.
            _ = try FolderCapture.deleteOne(db, key: key)
            try db.execute(
                sql: "UPDATE folder SET membershipRevision = membershipRevision + 1 WHERE id = ?",
                arguments: [folderID]
            )
            return .applied
        }
    }

    private static func requireFolder(_ db: Database, _ id: String) throws -> Folder {
        guard let folder = try Folder.fetchOne(db, key: id) else {
            throw StoreError.folderNotFound(id)
        }
        return folder
    }

    private static func requireCapture(_ db: Database, _ id: String) throws -> Capture {
        guard let capture = try Capture.fetchOne(db, key: id) else {
            throw StoreError.captureNotFound(id)
        }
        return capture
    }

    private static func writeMembership(
        _ db: Database,
        folder: Folder,
        captureID: String,
        state: FolderCaptureState,
        source: FolderCaptureSource,
        evidence: String?
    ) throws {
        let key = ["folderID": folder.id, "captureID": captureID]
        let previousRevision = try FolderCapture.fetchOne(db, key: key)?.revision ?? 0
        let membership = FolderCapture(
            folderID: folder.id,
            captureID: captureID,
            state: state,
            source: source,
            evidence: evidence,
            criteriaVersion: folder.criteriaVersion,
            revision: previousRevision + 1
        )
        try membership.save(db)
        try db.execute(
            sql: "UPDATE folder SET membershipRevision = membershipRevision + 1 WHERE id = ?",
            arguments: [folder.id]
        )
    }
}
