import XCTest
@testable import CapPick

@MainActor
final class FolderEditViewModelTests: XCTestCase {
    private var folderStore: GRDBFolderStore!
    private var savedCount = 0
    private var lastSavedFolder: Folder?
    private var lastApplyToExisting: Bool?

    override func setUpWithError() throws {
        folderStore = GRDBFolderStore(database: try AppDatabase.makeInMemory())
        savedCount = 0
        lastSavedFolder = nil
        lastApplyToExisting = nil
    }

    private func makeViewModel(mode: FolderEditViewModel.Mode) -> FolderEditViewModel {
        FolderEditViewModel(mode: mode, folderStore: folderStore, onSaved: { [weak self] folder, applyToExisting in
            self?.savedCount += 1
            self?.lastSavedFolder = folder
            self?.lastApplyToExisting = applyToExisting
        })
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

    // "기존 캡처에도 적용"은 생성 모드에서만 의미가 있다(§10.2) — 체크했으면 onSaved에 true로 전달돼야
    // 호출자(FolderListView/HomeView)가 RECLASS-01을 이어서 열 수 있다.
    func testCreateWithApplyToExistingCapturesPassesFlagToOnSaved() async throws {
        let viewModel = makeViewModel(mode: .create)
        viewModel.displayName = "운세"
        viewModel.applyToExistingCaptures = true

        await viewModel.save()

        XCTAssertEqual(lastApplyToExisting, true)
        XCTAssertEqual(lastSavedFolder?.displayName, "운세")
    }

    func testEditNeverPassesApplyToExistingRegardlessOfFlag() async throws {
        let existing = Folder(
            id: "f1", displayName: "이름", criteriaText: "기준",
            criteriaVersion: 1, criteriaState: .pending, membershipRevision: 0)
        try await folderStore.save(existing)
        let viewModel = makeViewModel(mode: .edit(existing))

        await viewModel.save()

        XCTAssertEqual(lastApplyToExisting, false)
    }

    func testHasUnsavedChangesReflectsFieldEdits() {
        let viewModel = makeViewModel(mode: .create)
        XCTAssertFalse(viewModel.hasUnsavedChanges)

        viewModel.displayName = "새 폴더"

        XCTAssertTrue(viewModel.hasUnsavedChanges)
    }
}
