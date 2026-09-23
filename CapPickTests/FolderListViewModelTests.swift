import XCTest
@testable import CapPick

@MainActor
final class FolderListViewModelTests: XCTestCase {
    private var database: AppDatabase!
    private var captureStore: GRDBCaptureStore!
    private var folderStore: GRDBFolderStore!
    private var viewModel: FolderListViewModel!

    override func setUpWithError() throws {
        database = try AppDatabase.makeInMemory()
        captureStore = GRDBCaptureStore(database: database)
        folderStore = GRDBFolderStore(database: database)
        viewModel = FolderListViewModel(folderStore: folderStore, captureStore: captureStore)
    }

    private func makeCapture(_ id: String, searchState: SearchState = .ready) -> Capture {
        Capture(
            id: id, photoAssetID: "asset-\(id)", capturedAt: Date(timeIntervalSince1970: 1_000),
            width: 100, height: 200, availability: .accessible, excludedAt: nil, favorite: false,
            contentRevision: 1, searchState: searchState, classificationState: .complete
        )
    }

    private func makeFolder(_ id: String, name: String) -> Folder {
        Folder(id: id, displayName: name, criteriaText: nil, criteriaVersion: 1, criteriaState: .pending, membershipRevision: 0)
    }

    func testLoadPopulatesTotalUnclassifiedAndFolderCounts() async throws {
        try await captureStore.save(makeCapture("inFolder"))
        try await captureStore.save(makeCapture("unclassified"))
        try await folderStore.save(makeFolder("f1", name: "면접 준비"))
        try await folderStore.addManually(captureID: "inFolder", to: "f1")

        await viewModel.load()

        XCTAssertEqual(viewModel.totalCount, 2)
        XCTAssertEqual(viewModel.unclassifiedCount, 1)
        XCTAssertEqual(viewModel.folders.map(\.displayName), ["면접 준비"])
        XCTAssertEqual(viewModel.count(for: viewModel.folders[0]), 1)
    }

    func testCountForFolderWithNoCapturesIsZero() async throws {
        try await folderStore.save(makeFolder("empty", name: "빈 폴더"))

        await viewModel.load()

        XCTAssertEqual(viewModel.count(for: viewModel.folders[0]), 0)
    }

    func testDeleteRemovesFolderAndReloadsList() async throws {
        try await folderStore.save(makeFolder("f1", name: "삭제할 폴더"))
        await viewModel.load()
        XCTAssertEqual(viewModel.folders.count, 1)

        await viewModel.delete(viewModel.folders[0])

        XCTAssertTrue(viewModel.folders.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
    }
}
