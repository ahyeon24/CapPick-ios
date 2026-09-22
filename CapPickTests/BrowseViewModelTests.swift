import XCTest
@testable import CapPick

@MainActor
final class BrowseViewModelTests: XCTestCase {
    func testLoadShowsAllVisibleCapturesNewestFirst() async throws {
        let store = GRDBCaptureStore(database: try AppDatabase.makeInMemory())
        try await store.save(Capture(
            id: "old", photoAssetID: "a", capturedAt: Date(timeIntervalSince1970: 1_000),
            width: 100, height: 200, availability: .accessible, excludedAt: nil, favorite: false,
            contentRevision: 1, searchState: .pending, classificationState: .pending
        ))
        try await store.save(Capture(
            id: "new", photoAssetID: "b", capturedAt: Date(timeIntervalSince1970: 2_000),
            width: 100, height: 200, availability: .accessible, excludedAt: nil, favorite: false,
            contentRevision: 1, searchState: .ready, classificationState: .complete
        ))
        let viewModel = BrowseViewModel(captureStore: store)

        await viewModel.load()

        // 미분석(pending) 캡처도 보여야 한다 — SEARCH-06: 빈 검색어는 미분석 이미지도 탐색 가능.
        XCTAssertEqual(viewModel.captures.map(\.id), ["new", "old"])
        XCTAssertNil(viewModel.errorMessage)
    }

    func testLoadWithNoCapturesLeavesEmptyListWithoutError() async throws {
        let store = GRDBCaptureStore(database: try AppDatabase.makeInMemory())
        let viewModel = BrowseViewModel(captureStore: store)

        await viewModel.load()

        XCTAssertTrue(viewModel.captures.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
    }
}
