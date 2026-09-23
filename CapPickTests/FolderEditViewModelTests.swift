import XCTest
@testable import CapPick

@MainActor
final class FolderEditViewModelTests: XCTestCase {
    private var folderStore: GRDBFolderStore!
    private var savedCount = 0

    override func setUpWithError() throws {
        folderStore = GRDBFolderStore(database: try AppDatabase.makeInMemory())
        savedCount = 0
    }

    private func makeViewModel(mode: FolderEditViewModel.Mode) -> FolderEditViewModel {
        FolderEditViewModel(mode: mode, folderStore: folderStore, onSaved: { [weak self] in self?.savedCount += 1 })
    }

    func testBlankNameIsInvalid() {
        let viewModel = makeViewModel(mode: .create)
        viewModel.displayName = "   "
        XCTAssertFalse(viewModel.isNameValid)
    }

    func testCreateSavesFolderWithCriteriaVersionOneAndPendingState() async throws {
        let viewModel = makeViewModel(mode: .create)
        viewModel.displayName = "면접 준비"
        viewModel.criteriaText = "면접 관련 스크린샷"

        await viewModel.save()

        XCTAssertEqual(savedCount, 1)
        let saved = try await folderStore.fetchAll()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].displayName, "면접 준비")
        XCTAssertEqual(saved[0].criteriaText, "면접 관련 스크린샷")
        XCTAssertEqual(saved[0].criteriaVersion, 1)
        XCTAssertEqual(saved[0].criteriaState, .pending)
    }

    func testEditRenamingOnlyKeepsCriteriaVersion() async throws {
        let existing = Folder(
            id: "f1", displayName: "옛 이름", criteriaText: "기존 기준",
            criteriaVersion: 3, criteriaState: .pending, membershipRevision: 0)
        try await folderStore.save(existing)
        let viewModel = makeViewModel(mode: .edit(existing))
        viewModel.displayName = "새 이름"
        // criteriaText는 안 건드림 — 이름만 바꾸는 케이스.

        await viewModel.save()

        let saved = try await folderStore.fetchAll().first
        XCTAssertEqual(saved?.displayName, "새 이름")
        XCTAssertEqual(saved?.criteriaVersion, 3, "이름만 바꾸면 criteriaVersion이 그대로여야 한다")
    }

    func testEditChangingCriteriaTextBumpsVersion() async throws {
        let existing = Folder(
            id: "f1", displayName: "이름", criteriaText: "기존 기준",
            criteriaVersion: 3, criteriaState: .pending, membershipRevision: 0)
        try await folderStore.save(existing)
        let viewModel = makeViewModel(mode: .edit(existing))
        viewModel.criteriaText = "새 기준"

        await viewModel.save()

        let saved = try await folderStore.fetchAll().first
        XCTAssertEqual(saved?.criteriaText, "새 기준")
        XCTAssertEqual(saved?.criteriaVersion, 4, "기준이 바뀌면 criteriaVersion이 올라가야 한다")
    }

    func testHasUnsavedChangesReflectsFieldEdits() {
        let viewModel = makeViewModel(mode: .create)
        XCTAssertFalse(viewModel.hasUnsavedChanges)

        viewModel.displayName = "새 폴더"

        XCTAssertTrue(viewModel.hasUnsavedChanges)
    }
}
