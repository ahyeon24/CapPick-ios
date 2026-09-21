import XCTest
import GRDB
@testable import CapPick

final class ScreenshotSyncTests: XCTestCase {
    private var database: AppDatabase!
    private var captures: GRDBCaptureStore!

    override func setUpWithError() throws {
        database = try AppDatabase.makeInMemory()
        captures = GRDBCaptureStore(database: database)
    }

    // MARK: - registerDiscovered

    func testNewScreenshotsAreRegisteredAsAccessibleAndPending() async throws {
        let result = try await captures.registerDiscovered([shot("a", at: 1_000), shot("b", at: 2_000)])
        XCTAssertEqual(result, ScreenshotSyncResult(registered: 2, restored: 0, becameUnavailable: 0))

        let all = try await captures.fetchAll()
        XCTAssertEqual(all.map(\.photoAssetID), ["b", "a"])
        XCTAssertEqual(Set(all.map(\.id)).count, 2)
        XCTAssertTrue(all.allSatisfy {
            $0.availability == .accessible && $0.searchState == .pending
                && $0.classificationState == .pending && !$0.favorite && $0.excludedAt == nil
        })

        let unclassified = try await captures.fetchUnclassified()
        XCTAssertTrue(unclassified.isEmpty, "분석 전 캡처를 미분류로 세지 않는다")
        let progress = try await captures.currentProgress()
        XCTAssertEqual(progress.total, 2)
        XCTAssertEqual(progress.searchPending, 2)
    }

    func testSyncingTheSameScreenshotsTwiceDoesNotDuplicate() async throws {
        _ = try await captures.registerDiscovered([shot("a"), shot("b")])
        let idsBefore = try await captures.fetchAll().map(\.id)

        let second = try await captures.registerDiscovered([shot("a"), shot("b")])
        XCTAssertEqual(second, ScreenshotSyncResult(registered: 0, restored: 0, becameUnavailable: 0))
        let idsAfter = try await captures.fetchAll().map(\.id)
        XCTAssertEqual(Set(idsAfter), Set(idsBefore))
    }

    func testDuplicateAssetIDsInOneBatchRegisterOnce() async throws {
        let result = try await captures.registerDiscovered([shot("a"), shot("a")])
        XCTAssertEqual(result.registered, 1)
    }

    func testMissingScreenshotBecomesUnavailableAndReturnsWhenSeenAgain() async throws {
        _ = try await captures.registerDiscovered([shot("a"), shot("b")])

        let lost = try await captures.registerDiscovered([shot("a")])
        XCTAssertEqual(lost, ScreenshotSyncResult(registered: 0, restored: 0, becameUnavailable: 1))
        var visible = try await captures.fetchAll().map(\.photoAssetID)
        XCTAssertEqual(visible, ["a"])

        let back = try await captures.registerDiscovered([shot("a"), shot("b")])
        XCTAssertEqual(back, ScreenshotSyncResult(registered: 0, restored: 1, becameUnavailable: 0))
        visible = try await captures.fetchAll().map(\.photoAssetID).sorted()
        XCTAssertEqual(visible, ["a", "b"])
    }

    func testExcludedCaptureIsNeverRegisteredAgain() async throws {
        _ = try await captures.registerDiscovered([shot("a")])
        try await database.dbWriter.write { db in
            try db.execute(sql: "UPDATE capture SET excludedAt = ? WHERE photoAssetID = 'a'", arguments: [Date()])
        }

        let result = try await captures.registerDiscovered([shot("a")])
        XCTAssertEqual(result.registered, 0)
        let visible = try await captures.fetchAll()
        XCTAssertTrue(visible.isEmpty)
        let rows = try await database.dbWriter.read { db in try Capture.fetchCount(db) }
        XCTAssertEqual(rows, 1)
    }

    // MARK: - ScreenshotSyncService

    func testServiceSkipsWithoutReadPermissionAndKeepsExistingCaptures() async throws {
        _ = try await captures.registerDiscovered([shot("a")])

        for status in [PhotoAuthorization.notDetermined, .denied, .restricted] {
            let library = FakeScreenshotLibrary(authorization: status)
            let service = ScreenshotSyncService(library: library, captureStore: captures)

            let outcome = try await service.sync()
            XCTAssertEqual(outcome, .skipped(status))
            XCTAssertEqual(library.fetchCount, 0)
        }
        let visible = try await captures.fetchAll()
        XCTAssertEqual(visible.count, 1, "권한이 없을 때 기존 캡처를 접근 불가로 바꾸면 안 된다")
    }

    func testServiceSyncsWhenAuthorizedOrLimited() async throws {
        for status in [PhotoAuthorization.authorized, .limited] {
            let store = GRDBCaptureStore(database: try AppDatabase.makeInMemory())
            let library = FakeScreenshotLibrary(authorization: status, screenshots: [shot("a")])
            let service = ScreenshotSyncService(library: library, captureStore: store)

            let outcome = try await service.sync()
            XCTAssertEqual(outcome, .synced(ScreenshotSyncResult(registered: 1, restored: 0, becameUnavailable: 0)))
        }
    }
}
