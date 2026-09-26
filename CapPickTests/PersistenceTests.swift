import XCTest
import GRDB
@testable import CapPick

final class PersistenceTests: XCTestCase {
    private var database: AppDatabase!
    private var captures: GRDBCaptureStore!
    private var folders: GRDBFolderStore!
    private var reclassifications: GRDBReclassificationStore!

    override func setUpWithError() throws {
        database = try AppDatabase.makeInMemory()
        captures = GRDBCaptureStore(database: database)
        folders = GRDBFolderStore(database: database)
        reclassifications = GRDBReclassificationStore(database: database)
    }

    private func makeCapture(
        _ id: String,
        capturedAt: TimeInterval = 1_000,
        availability: CaptureAvailability = .accessible,
        excluded: Bool = false,
        searchState: SearchState = .ready,
        classificationState: ClassificationState = .complete
    ) -> Capture {
        Capture(
            id: id,
            photoAssetID: "asset-\(id)",
            capturedAt: Date(timeIntervalSince1970: capturedAt),
            width: 1170,
            height: 2532,
            availability: availability,
            excludedAt: excluded ? Date(timeIntervalSince1970: 2_000) : nil,
            favorite: false,
            contentRevision: 1,
            searchState: searchState,
            classificationState: classificationState
        )
    }

    private func saveAnalysis(
        for captureID: String, ocrText: String = "", searchText: String = "", embedding: [Double] = [],
        embeddingModelVersion: String = "v1"
    ) async throws {
        try await captures.saveAnalysis(
            CaptureAnalysis(
                captureID: captureID, contentRevision: 1, analysisRevision: 1,
                ocrText: ocrText, observedEvidence: [], modelVersion: "m1"),
            searchDocument: SearchDocument(
                captureID: captureID, sourceAnalysisRevision: 1, searchText: searchText,
                embedding: embedding, embeddingModelVersion: embeddingModelVersion, state: "ready")
        )
    }

    private func makeFolder(_ id: String, criteriaVersion: Int = 1) -> Folder {
        Folder(
            id: id,
            displayName: id,
            criteriaText: "기준 \(id)",
            criteriaVersion: criteriaVersion,
            criteriaState: .ready,
            membershipRevision: 0
        )
    }

    // MARK: - 목록 조회 규칙 (ERD §3)

    func testFetchAllExcludesUnavailableAndExcludedAndSortsNewestFirst() async throws {
        try await captures.save(makeCapture("old", capturedAt: 1_000))
        try await captures.save(makeCapture("new", capturedAt: 3_000))
        try await captures.save(makeCapture("gone", availability: .unavailable))
        try await captures.save(makeCapture("excluded", excluded: true))

        let ids = try await captures.fetchAll().map(\.id)
        XCTAssertEqual(ids, ["new", "old"])
    }

    func testUnclassifiedRequiresReadyCompleteAndNoPresentMembership() async throws {
        try await captures.save(makeCapture("target"))
        try await captures.save(makeCapture("searchPending", searchState: .pending))
        try await captures.save(makeCapture("classificationPending", classificationState: .pending))
        try await captures.save(makeCapture("classificationFailed", classificationState: .failed))
        try await captures.save(makeCapture("excluded", excluded: true))
        try await captures.save(makeCapture("inFolder"))
        try await folders.save(makeFolder("f1"))
        try await folders.addManually(captureID: "inFolder", to: "f1")

        let ids = try await captures.fetchUnclassified().map(\.id)
        XCTAssertEqual(ids, ["target"])
    }

    func testRemovingLastMembershipMakesCaptureUnclassifiedAgain() async throws {
        try await captures.save(makeCapture("c1"))
        try await folders.save(makeFolder("f1"))

        try await folders.addManually(captureID: "c1", to: "f1")
        var unclassified = try await captures.fetchUnclassified()
        XCTAssertTrue(unclassified.isEmpty)

        try await folders.removeManually(captureID: "c1", from: "f1")
        unclassified = try await captures.fetchUnclassified()
        XCTAssertEqual(unclassified.map(\.id), ["c1"])
    }

    func testFetchInFolderReturnsOnlyPresentVisibleCaptures() async throws {
        try await captures.save(makeCapture("shown", capturedAt: 2_000))
        try await captures.save(makeCapture("removed", capturedAt: 3_000))
        try await captures.save(makeCapture("excluded", capturedAt: 4_000, excluded: true))
        try await captures.save(makeCapture("unrelated", capturedAt: 5_000))
        let folder = makeFolder("f1")
        try await folders.save(folder)
        try await folders.addManually(captureID: "shown", to: "f1")
        try await folders.addManually(captureID: "removed", to: "f1")
        try await folders.removeManually(captureID: "removed", from: "f1")
        try await folders.addManually(captureID: "excluded", to: "f1")

        let ids = try await captures.fetch(in: folder).map(\.id)
        XCTAssertEqual(ids, ["shown"])
    }

    func testProgressSeparatesSearchReadyFromClassificationState() async throws {
        try await captures.save(makeCapture("ready"))
        try await captures.save(makeCapture("classifying", classificationState: .processing))
        try await captures.save(makeCapture("classifyFailed", classificationState: .failed))
        try await captures.save(makeCapture("searchPending", searchState: .pending, classificationState: .pending))
        try await captures.save(makeCapture("searchFailed", searchState: .failed, classificationState: .pending))
        try await captures.save(makeCapture("excluded", excluded: true))

        let progress = try await captures.currentProgress()
        XCTAssertEqual(progress, AnalysisProgress(
            total: 5,
            searchReady: 3,
            searchPending: 1,
            searchFailed: 1,
            classificationPending: 1,
            classificationFailed: 1
        ))
    }

    // MARK: - 자동 분석 큐 (AnalysisQueueService가 쓰는 저장소 메서드)

    func testNextPendingForAnalysisReturnsMostRecentPendingOnly() async throws {
        try await captures.save(makeCapture("older", capturedAt: 1_000, searchState: .pending))
        try await captures.save(makeCapture("newer", capturedAt: 2_000, searchState: .pending))
        try await captures.save(makeCapture("alreadyReady", capturedAt: 3_000, searchState: .ready))
        try await captures.save(makeCapture("unavailable", capturedAt: 4_000, availability: .unavailable, searchState: .pending))
        try await captures.save(makeCapture("excluded", capturedAt: 5_000, excluded: true, searchState: .pending))

        let next = try await captures.nextPendingForAnalysis()
        XCTAssertEqual(next?.id, "newer")
    }

    func testNextPendingForAnalysisReturnsNilWhenNoneLeft() async throws {
        try await captures.save(makeCapture("ready", searchState: .ready))
        try await captures.save(makeCapture("processing", searchState: .processing))
        try await captures.save(makeCapture("failed", searchState: .failed))

        let next = try await captures.nextPendingForAnalysis()
        XCTAssertNil(next)
    }

    func testMarkSearchProcessingAndFailedTransitionState() async throws {
        try await captures.save(makeCapture("c1", searchState: .pending))

        try await captures.markSearchProcessing("c1")
        var state = try await captures.fetchAll().first { $0.id == "c1" }?.searchState
        XCTAssertEqual(state, .processing)

        try await captures.markSearchFailed("c1")
        state = try await captures.fetchAll().first { $0.id == "c1" }?.searchState
        XCTAssertEqual(state, .failed)
    }

    func testResetStuckProcessingOnlyTouchesProcessingRows() async throws {
        try await captures.save(makeCapture("stuck", searchState: .processing))
        try await captures.save(makeCapture("ready", searchState: .ready))
        try await captures.save(makeCapture("failed", searchState: .failed))

        try await captures.resetStuckProcessing()

        let states = Dictionary(uniqueKeysWithValues: try await captures.fetchAll().map { ($0.id, $0.searchState) })
        XCTAssertEqual(states["stuck"], .pending)
        XCTAssertEqual(states["ready"], .ready)
        XCTAssertEqual(states["failed"], .failed)
    }

    // MARK: - 검색 후보 (SearchService가 쓰는 저장소 메서드)

    func testFetchSearchCandidatesOnlyIncludesAnalyzedCaptures() async throws {
        try await captures.save(makeCapture("analyzed", capturedAt: 1_000, searchState: .ready))
        try await saveAnalysis(for: "analyzed", ocrText: "면접 질문", embedding: [1, 0])
        try await captures.save(makeCapture("pending", capturedAt: 2_000, searchState: .pending))
        try await captures.save(makeCapture("failed", capturedAt: 3_000, searchState: .failed))

        let candidates = try await captures.fetchSearchCandidates(capturedFrom: nil, capturedBefore: nil, folderID: nil)

        XCTAssertEqual(candidates.map(\.capture.id), ["analyzed"])
        XCTAssertEqual(candidates.first?.ocrText, "면접 질문")
        XCTAssertEqual(candidates.first?.embedding, [1, 0])
    }

    func testFetchSearchCandidatesExcludesUnavailableAndExcluded() async throws {
        try await captures.save(makeCapture("visible", searchState: .ready))
        try await saveAnalysis(for: "visible")
        try await captures.save(makeCapture("gone", availability: .unavailable, searchState: .ready))
        try await saveAnalysis(for: "gone")
        try await captures.save(makeCapture("excluded", excluded: true, searchState: .ready))
        try await saveAnalysis(for: "excluded")

        let candidates = try await captures.fetchSearchCandidates(capturedFrom: nil, capturedBefore: nil, folderID: nil)

        XCTAssertEqual(candidates.map(\.capture.id), ["visible"])
    }

    func testFetchSearchCandidatesFiltersByCapturedDateRangeStartInclusiveEndExclusive() async throws {
        try await captures.save(makeCapture("before", capturedAt: 999, searchState: .ready))
        try await saveAnalysis(for: "before")
        try await captures.save(makeCapture("atStart", capturedAt: 1_000, searchState: .ready))
        try await saveAnalysis(for: "atStart")
        try await captures.save(makeCapture("inRange", capturedAt: 1_500, searchState: .ready))
        try await saveAnalysis(for: "inRange")
        try await captures.save(makeCapture("atEnd", capturedAt: 2_000, searchState: .ready))
        try await saveAnalysis(for: "atEnd")

        let candidates = try await captures.fetchSearchCandidates(
            capturedFrom: Date(timeIntervalSince1970: 1_000), capturedBefore: Date(timeIntervalSince1970: 2_000),
            folderID: nil)

        XCTAssertEqual(Set(candidates.map(\.capture.id)), ["atStart", "inRange"])
    }

    func testCurrentEmbeddingModelVersionReturnsNilWhenNothingAnalyzed() async throws {
        try await captures.save(makeCapture("pending", searchState: .pending))

        let version = try await captures.currentEmbeddingModelVersion()

        XCTAssertNil(version)
    }

    func testCurrentEmbeddingModelVersionReturnsStoredVersion() async throws {
        try await captures.save(makeCapture("c1"))
        try await saveAnalysis(for: "c1", embeddingModelVersion: "gemini-embedding-001")

        let version = try await captures.currentEmbeddingModelVersion()

        XCTAssertEqual(version, "gemini-embedding-001")
    }

    func testFetchSearchCandidatesFiltersByFolderScope() async throws {
        try await captures.save(makeCapture("inFolder", searchState: .ready))
        try await saveAnalysis(for: "inFolder")
        try await captures.save(makeCapture("notInFolder", searchState: .ready))
        try await saveAnalysis(for: "notInFolder")
        try await folders.save(makeFolder("f1"))
        try await folders.addManually(captureID: "inFolder", to: "f1")

        let candidates = try await captures.fetchSearchCandidates(capturedFrom: nil, capturedBefore: nil, folderID: "f1")

        XCTAssertEqual(candidates.map(\.capture.id), ["inFolder"])
    }

    func testUnclassifiedCountMatchesFetchUnclassifiedCount() async throws {
        try await captures.save(makeCapture("target"))
        try await captures.save(makeCapture("searchPending", searchState: .pending))
        try await captures.save(makeCapture("excluded", excluded: true))

        let count = try await captures.unclassifiedCount()

        XCTAssertEqual(count, 1)
    }

    func testFetchFolderCaptureCountsOnlyCountsPresentVisibleMemberships() async throws {
        try await captures.save(makeCapture("shown"))
        try await captures.save(makeCapture("removed"))
        try await captures.save(makeCapture("excluded", excluded: true))
        try await folders.save(makeFolder("f1"))
        try await folders.save(makeFolder("empty"))
        try await folders.addManually(captureID: "shown", to: "f1")
        try await folders.addManually(captureID: "removed", to: "f1")
        try await folders.removeManually(captureID: "removed", from: "f1")
        try await folders.addManually(captureID: "excluded", to: "f1")

        let counts = try await captures.fetchFolderCaptureCounts()

        XCTAssertEqual(counts["f1"], 1)
        XCTAssertNil(counts["empty"], "소속 캡처가 0장인 폴더는 결과에 키가 없어야 한다")
    }

    // MARK: - DETAIL-01 저장소 메서드

    func testFetchCaptureReturnsCaptureOrNil() async throws {
        try await captures.save(makeCapture("c1"))

        let found = try await captures.fetchCapture(id: "c1")
        let missing = try await captures.fetchCapture(id: "nope")

        XCTAssertEqual(found?.id, "c1")
        XCTAssertNil(missing)
    }

    func testSetFavoriteTogglesField() async throws {
        try await captures.save(makeCapture("c1"))

        try await captures.setFavorite("c1", favorite: true)
        let afterSettingTrue = try await captures.fetchCapture(id: "c1")
        XCTAssertEqual(afterSettingTrue?.favorite, true)

        try await captures.setFavorite("c1", favorite: false)
        let afterSettingFalse = try await captures.fetchCapture(id: "c1")
        XCTAssertEqual(afterSettingFalse?.favorite, false)
    }

    func testExcludeSetsExcludedAtAndRemovesFromVisibleQueries() async throws {
        try await captures.save(makeCapture("c1"))
        let now = Date(timeIntervalSince1970: 5_000)

        try await captures.exclude("c1", at: now)

        let saved = try await captures.fetchCapture(id: "c1")
        XCTAssertEqual(saved?.excludedAt, now)
        let allCaptures = try await captures.fetchAll()
        XCTAssertTrue(allCaptures.isEmpty, "제외된 캡처는 Self.visible 규칙으로 목록에서 빠져야 한다")
    }

    func testFetchFoldersContainingReturnsOnlyPresentMemberships() async throws {
        try await captures.save(makeCapture("c1"))
        try await folders.save(makeFolder("f1"))
        try await folders.save(makeFolder("f2"))
        try await folders.addManually(captureID: "c1", to: "f1")
        try await folders.addManually(captureID: "c1", to: "f2")
        try await folders.removeManually(captureID: "c1", from: "f2")

        let containing = try await folders.fetchFolders(containing: "c1")

        XCTAssertEqual(containing.map(\.id), ["f1"])
    }

    func testProgressIsZeroWhenNoCaptures() async throws {
        let progress = try await captures.currentProgress()
        XCTAssertEqual(progress.total, 0)
        XCTAssertEqual(progress.searchReady, 0)
    }

    // MARK: - 폴더 소속 규칙 (ERD §3 표)

    func testAutoMatchAddsPresentAutoMembershipAndBumpsRevision() async throws {
        try await captures.save(makeCapture("c1"))
        try await folders.save(makeFolder("f1"))

        let result = try await folders.applyAutoMatch(
            captureID: "c1", to: "f1", evidence: "면접 질문 문구", criteriaVersion: 1
        )
        XCTAssertEqual(result, .applied)

        let memberships = try await folders.fetchMemberships(of: "f1")
        XCTAssertEqual(memberships.count, 1)
        XCTAssertEqual(memberships[0].state, .present)
        XCTAssertEqual(memberships[0].source, .auto)
        XCTAssertEqual(memberships[0].evidence, "면접 질문 문구")
        let folder = try await folders.fetchAll().first
        XCTAssertEqual(folder?.membershipRevision, 1)
    }

    func testAutoMatchNeverOverridesUserRemoval() async throws {
        try await captures.save(makeCapture("c1"))
        try await folders.save(makeFolder("f1"))
        try await folders.addManually(captureID: "c1", to: "f1")
        try await folders.removeManually(captureID: "c1", from: "f1")

        let result = try await folders.applyAutoMatch(
            captureID: "c1", to: "f1", evidence: nil, criteriaVersion: 1
        )
        XCTAssertEqual(result, .ignoredUserDecision)
        let memberships = try await folders.fetchMemberships(of: "f1")
        XCTAssertEqual(memberships.first?.state, .blocked)
    }

    func testAutoMatchDoesNotOverrideManualMembership() async throws {
        try await captures.save(makeCapture("c1"))
        try await folders.save(makeFolder("f1"))
        try await folders.addManually(captureID: "c1", to: "f1")

        let result = try await folders.applyAutoMatch(
            captureID: "c1", to: "f1", evidence: "x", criteriaVersion: 1
        )
        XCTAssertEqual(result, .ignoredUserDecision)
        let memberships = try await folders.fetchMemberships(of: "f1")
        XCTAssertEqual(memberships.first?.source, .manual)
    }

    func testManualAddClearsBlockedRecord() async throws {
        try await captures.save(makeCapture("c1"))
        try await folders.save(makeFolder("f1"))
        try await folders.removeManually(captureID: "c1", from: "f1")
        try await folders.addManually(captureID: "c1", to: "f1")

        let memberships = try await folders.fetchMemberships(of: "f1")
        XCTAssertEqual(memberships.count, 1)
        XCTAssertEqual(memberships[0].state, .present)
        XCTAssertEqual(memberships[0].source, .manual)
        XCTAssertEqual(memberships[0].revision, 2)
    }

    func testAutoMatchIgnoredWhenCriteriaVersionIsStale() async throws {
        try await captures.save(makeCapture("c1"))
        try await folders.save(makeFolder("f1", criteriaVersion: 2))

        let result = try await folders.applyAutoMatch(
            captureID: "c1", to: "f1", evidence: nil, criteriaVersion: 1
        )
        XCTAssertEqual(result, .ignoredStaleCriteria)
        let memberships = try await folders.fetchMemberships(of: "f1")
        XCTAssertTrue(memberships.isEmpty)
    }

    func testAutoMatchIgnoredForUnavailableOrExcludedCapture() async throws {
        try await captures.save(makeCapture("gone", availability: .unavailable))
        try await captures.save(makeCapture("excluded", excluded: true))
        try await folders.save(makeFolder("f1"))

        let gone = try await folders.applyAutoMatch(
            captureID: "gone", to: "f1", evidence: nil, criteriaVersion: 1
        )
        let excluded = try await folders.applyAutoMatch(
            captureID: "excluded", to: "f1", evidence: nil, criteriaVersion: 1
        )
        XCTAssertEqual(gone, .ignoredCaptureUnavailable)
        XCTAssertEqual(excluded, .ignoredCaptureUnavailable)
    }

    func testFetchFolderReturnsFolderOrNil() async throws {
        try await folders.save(makeFolder("f1"))

        let found = try await folders.fetchFolder(id: "f1")
        XCTAssertEqual(found?.id, "f1")
        let missing = try await folders.fetchFolder(id: "missing")
        XCTAssertNil(missing)
    }

    // RECLASS-01의 "확인된 재분류의 불일치" 규칙(ERD §3) — auto+present만 제거하고 manual은 절대 안 건드린다.
    func testAutoMismatchRemovalRemovesOnlyAutoPresentMembership() async throws {
        try await captures.save(makeCapture("c1"))
        try await folders.save(makeFolder("f1"))
        _ = try await folders.applyAutoMatch(captureID: "c1", to: "f1", evidence: "e", criteriaVersion: 1)

        let result = try await folders.applyAutoMismatchRemoval(captureID: "c1", from: "f1", criteriaVersion: 1)

        XCTAssertEqual(result, .applied)
        let memberships = try await folders.fetchMemberships(of: "f1")
        XCTAssertTrue(memberships.isEmpty, "행 자체가 지워져야 나중에 다시 자유롭게 auto-match될 수 있다")
        let updatedFolder = try await folders.fetchAll().first
        XCTAssertEqual(updatedFolder?.membershipRevision, 2)
    }

    func testAutoMismatchRemovalNeverTouchesManualMembership() async throws {
        try await captures.save(makeCapture("c1"))
        try await folders.save(makeFolder("f1"))
        try await folders.addManually(captureID: "c1", to: "f1")

        let result = try await folders.applyAutoMismatchRemoval(captureID: "c1", from: "f1", criteriaVersion: 1)

        XCTAssertEqual(result, .ignoredUserDecision)
        let memberships = try await folders.fetchMemberships(of: "f1")
        XCTAssertEqual(memberships.first?.state, .present, "manual 소속은 재분류로 절대 제거되지 않는다")
    }

    func testAutoMismatchRemovalIgnoredWhenCriteriaVersionIsStale() async throws {
        try await captures.save(makeCapture("c1"))
        try await folders.save(makeFolder("f1"))
        _ = try await folders.applyAutoMatch(captureID: "c1", to: "f1", evidence: nil, criteriaVersion: 1)
        try await folders.save(Folder(
            id: "f1", displayName: "f1", criteriaText: "새 기준", criteriaVersion: 2,
            criteriaState: .pending, membershipRevision: 1))

        let result = try await folders.applyAutoMismatchRemoval(captureID: "c1", from: "f1", criteriaVersion: 1)

        XCTAssertEqual(result, .ignoredStaleCriteria)
        let memberships = try await folders.fetchMemberships(of: "f1")
        XCTAssertEqual(memberships.first?.state, .present)
    }

    func testFetchAnalyzedCapturesReturnsOnlySearchReadyVisibleCaptures() async throws {
        try await captures.save(makeCapture("ready", searchState: .ready))
        try await captures.save(makeCapture("pending", searchState: .pending))
        try await captures.save(makeCapture("failed", searchState: .failed))
        try await captures.save(makeCapture("excludedReady", excluded: true, searchState: .ready))

        let analyzed = try await captures.fetchAnalyzedCaptures()

        XCTAssertEqual(analyzed.map(\.id), ["ready"])
    }

    func testReclassificationRunAndItemsRoundTrip() async throws {
        try await folders.save(makeFolder("f1"))
        try await captures.save(makeCapture("c1"))

        let noneYet = try await reclassifications.activeRun(folderID: "f1")
        XCTAssertNil(noneYet)

        let run = try await reclassifications.createRun(
            folderID: "f1", criteriaVersion: 1, membershipRevision: 0, mode: .reclassify)

        let active = try await reclassifications.activeRun(folderID: "f1")
        XCTAssertEqual(active?.id, run.id, "만들자마자 previewing 상태라 activeRun에 잡혀야 한다")

        try await reclassifications.saveItems([
            ReclassificationItem(runID: run.id, captureID: "c1", action: .add, evidence: "e", expectedMembershipRevision: 0, state: ReclassificationItemState.pending),
        ])
        let items = try await reclassifications.fetchItems(runID: run.id)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].action, .add)

        try await reclassifications.setItemState(runID: run.id, captureID: "c1", state: ReclassificationItemState.applied)
        try await reclassifications.setRunState(run.id, state: ReclassificationRunState.applied)

        let updatedItems = try await reclassifications.fetchItems(runID: run.id)
        XCTAssertEqual(updatedItems.first?.state, ReclassificationItemState.applied)
        let stillActive = try await reclassifications.activeRun(folderID: "f1")
        XCTAssertNil(stillActive, "확정된 실행은 더 이상 activeRun이 아니다 — 새 재분류를 막지 않는다")
    }

    func testMembershipOnMissingFolderOrCaptureThrows() async throws {
        try await captures.save(makeCapture("c1"))
        try await folders.save(makeFolder("f1"))

        do {
            try await folders.addManually(captureID: "c1", to: "nope")
            XCTFail("expected folderNotFound")
        } catch let error as StoreError {
            XCTAssertEqual(error, .folderNotFound("nope"))
        }
        do {
            try await folders.addManually(captureID: "nope", to: "f1")
            XCTFail("expected captureNotFound")
        } catch let error as StoreError {
            XCTAssertEqual(error, .captureNotFound("nope"))
        }
    }

    // MARK: - 폴더 저장·삭제

    func testSavingFolderPreservesMembershipRevision() async throws {
        try await captures.save(makeCapture("c1"))
        try await folders.save(makeFolder("f1"))
        try await folders.addManually(captureID: "c1", to: "f1")

        var renamed = makeFolder("f1")
        renamed.displayName = "새 이름"
        try await folders.save(renamed)

        let saved = try await folders.fetchAll().first
        XCTAssertEqual(saved?.displayName, "새 이름")
        XCTAssertEqual(saved?.membershipRevision, 1)
        let memberships = try await folders.fetchMemberships(of: "f1")
        XCTAssertEqual(memberships.count, 1)
    }

    func testDeletingFolderRemovesMembershipsButKeepsCaptures() async throws {
        try await captures.save(makeCapture("c1"))
        try await folders.save(makeFolder("f1"))
        try await folders.addManually(captureID: "c1", to: "f1")

        try await folders.delete(id: "f1")

        let allFolders = try await folders.fetchAll()
        XCTAssertTrue(allFolders.isEmpty)
        let membershipRows = try await database.dbWriter.read { db in
            try FolderCapture.fetchCount(db)
        }
        XCTAssertEqual(membershipRows, 0)
        let unclassified = try await captures.fetchUnclassified()
        XCTAssertEqual(unclassified.map(\.id), ["c1"])
    }

    // MARK: - 레코드 왕복 저장

    func testAnalysisAndSearchDocumentRoundTrip() async throws {
        try await captures.save(makeCapture("c1"))
        let analysis = CaptureAnalysis(
            captureID: "c1", contentRevision: 1, analysisRevision: 2,
            ocrText: "실습 1", observedEvidence: ["행렬곱 문제", "Python 파일명"], modelVersion: "m1"
        )
        let document = SearchDocument(
            captureID: "c1", sourceAnalysisRevision: 2, searchText: "행렬곱",
            embedding: [0.25, -0.5, 1.0], embeddingModelVersion: "e1", state: "ready"
        )

        try await database.dbWriter.write { db in
            try analysis.save(db)
            try document.save(db)
        }
        let loaded = try await database.dbWriter.read { db in
            (try CaptureAnalysis.fetchOne(db, key: "c1"), try SearchDocument.fetchOne(db, key: "c1"))
        }
        XCTAssertEqual(loaded.0, analysis)
        XCTAssertEqual(loaded.1, document)
    }

    func testOnDiskDatabaseKeepsDataAfterReopening() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cappick-\(UUID().uuidString).sqlite").path
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }

        let first = try AppDatabase(DatabasePool(path: path))
        try await GRDBCaptureStore(database: first).save(makeCapture("c1"))
        let firstFolders = GRDBFolderStore(database: first)
        try await firstFolders.save(makeFolder("f1"))
        try await firstFolders.addManually(captureID: "c1", to: "f1")

        let reopened = try AppDatabase(DatabasePool(path: path))
        let savedCaptures = try await GRDBCaptureStore(database: reopened).fetchAll()
        let memberships = try await GRDBFolderStore(database: reopened).fetchMemberships(of: "f1")
        XCTAssertEqual(savedCaptures.map(\.id), ["c1"])
        XCTAssertEqual(memberships.first?.source, .manual)
    }

    func testLocalTaskIdempotencyKeyIsUnique() async throws {
        func task(_ id: String) -> LocalTask {
            LocalTask(
                id: id, captureID: nil, folderID: nil, kind: .contentAnalysis, inputRevision: 1,
                criteriaVersion: nil, serverJobID: nil, idempotencyKey: "same-key",
                state: .pending, attempts: 0, errorCode: nil, nextRetryAt: nil
            )
        }
        let first = task("t1")
        let second = task("t2")
        try await database.dbWriter.write { db in try first.save(db) }
        do {
            try await database.dbWriter.write { db in try second.insert(db) }
            XCTFail("expected unique violation")
        } catch is DatabaseError {
            // 같은 멱등 키의 두 번째 작업은 저장되지 않는다.
        }
    }

    // MARK: - 앱 데이터 삭제 (기능명세서 §3.8)

    func testEraseAllLocalDataEmptiesEveryTable() async throws {
        try await captures.save(makeCapture("c1"))
        try await saveAnalysis(for: "c1", ocrText: "ocr", searchText: "search")
        let folder = makeFolder("f1")
        try await folders.save(folder)
        try await database.dbWriter.write { db in
            try FolderCapture(
                folderID: "f1", captureID: "c1", state: .present, source: .manual,
                evidence: nil, criteriaVersion: 1, revision: 1
            ).insert(db)
            try LocalTask(
                id: "t1", captureID: "c1", folderID: nil, kind: .contentAnalysis, inputRevision: 1,
                criteriaVersion: nil, serverJobID: nil, idempotencyKey: "key-1",
                state: .pending, attempts: 0, errorCode: nil, nextRetryAt: nil
            ).insert(db)
            try AppStateEntry(key: "onboardingCompleted", value: "true").insert(db)
        }
        let run = try await reclassifications.createRun(
            folderID: "f1", criteriaVersion: 1, membershipRevision: 0, mode: .reclassify)
        try await reclassifications.saveItems([
            ReclassificationItem(runID: run.id, captureID: "c1", action: .add, evidence: nil, expectedMembershipRevision: nil, state: ReclassificationItemState.pending),
        ])

        try await database.eraseAllLocalData()

        try await database.dbWriter.read { db in
            for table in [
                "capture", "captureAnalysis", "searchDocument", "folder", "folderCapture",
                "localTask", "reclassificationRun", "reclassificationItem", "appState",
            ] {
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)")
                XCTAssertEqual(count, 0, "\(table) should be empty after eraseAllLocalData")
            }
        }
    }
}
