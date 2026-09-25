import Foundation
import Observation

// 화면설계서 FOLDER-02. "이름으로 AI가 기준을 제안"하는 부분(§10.2)은 아직 없다(folder_criteria
// Job 미구현) — 분류 기준은 사용자가 원하면 직접 적는 텍스트일 뿐이다. "기존 캡처에도 적용"은
// RECLASS-01(ReclassificationView)로 이어진다(2026-09-25, classification Job이 생긴 뒤 추가).
@MainActor @Observable
final class FolderEditViewModel {
    enum Mode {
        case create
        case edit(Folder)
    }

    var displayName: String
    var criteriaText: String
    /// 생성 모드에서만 의미가 있다(§10.2: "직접 생성 시 선택") — View가 .create일 때만 보여준다.
    var applyToExistingCaptures = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    private let mode: Mode
    private let folderStore: any FolderStoring
    /// 저장된 폴더와, 저장 직후 RECLASS-01(기존 캡처에 적용)로 이어가야 하는지를 함께 넘긴다.
    private let onSaved: (Folder, Bool) -> Void
    private let initialDisplayName: String
    private let initialCriteriaText: String

    var title: String {
        switch mode {
        case .create: "새 폴더"
        case .edit: "폴더 수정"
        }
    }

    /// "기존 캡처에도 적용" 토글은 생성 모드에서만 보여준다(§10.2).
    var isCreating: Bool {
        if case .create = mode { true } else { false }
    }

    var isNameValid: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 취소 확인 여부를 View가 판단하는 데 쓴다(화면설계서: "변경사항이 있으면 버리기 확인").
    var hasUnsavedChanges: Bool {
        displayName != initialDisplayName || criteriaText != initialCriteriaText
    }

    init(mode: Mode, folderStore: any FolderStoring, onSaved: @escaping (Folder, Bool) -> Void) {
        self.mode = mode
        self.folderStore = folderStore
        self.onSaved = onSaved
        let name: String
        let criteria: String
        switch mode {
        case .create:
            name = ""
            criteria = ""
        case .edit(let folder):
            name = folder.displayName
            criteria = folder.criteriaText ?? ""
        }
        displayName = name
        criteriaText = criteria
        initialDisplayName = name
        initialCriteriaText = criteria
    }

    func save() async {
        guard isNameValid else { return }
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil

        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCriteria = criteriaText.trimmingCharacters(in: .whitespacesAndNewlines)
        let criteriaTextValue = trimmedCriteria.isEmpty ? nil : trimmedCriteria

        do {
            switch mode {
            case .create:
                let folder = Folder(
                    id: UUID().uuidString, displayName: trimmedName, criteriaText: criteriaTextValue,
                    criteriaVersion: 1, criteriaState: .pending, membershipRevision: 0
                )
                try await folderStore.save(folder)
                onSaved(folder, applyToExistingCaptures)
            case .edit(let existing):
                // 이름만 바꾸면 criteriaVersion 그대로, 기준 자체가 바뀌면 올린다 — "이름만 변경하면
                // AI 재분류 요청 없음"(§10.2)과 ERD 의도에 맞춘다. edit에서는 RECLASS-01로 자동
                // 이어가지 않는다 — "기존 캡처는 자동으로 이동하지 않아요"(§10.2 기준 변경 안내),
                // 재분류하고 싶으면 FOLDER-01의 "재분류" 메뉴를 별도로 쓴다.
                let criteriaChanged = criteriaTextValue != existing.criteriaText
                let folder = Folder(
                    id: existing.id, displayName: trimmedName, criteriaText: criteriaTextValue,
                    criteriaVersion: criteriaChanged ? existing.criteriaVersion + 1 : existing.criteriaVersion,
                    criteriaState: .pending, membershipRevision: existing.membershipRevision
                )
                try await folderStore.save(folder)
                onSaved(folder, false)
            }
        } catch {
            errorMessage = "폴더를 저장하지 못했어요."
        }
    }
}
