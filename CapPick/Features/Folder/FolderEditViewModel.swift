import Foundation
import Observation

// 화면설계서 FOLDER-02. "이름으로 AI가 기준을 제안"하는 부분(§10.2)은 Gemini 호출이 필요해서
// 이번엔 없다 — 분류 기준은 사용자가 원하면 직접 적는 텍스트일 뿐이다. "기존 캡처에도 적용"
// 체크박스+RECLASS-01도 없다 — 그걸 실제로 처리할 자동 분류 Job(folder_criteria/classification)
// 자체가 서버에 아직 없다.
@MainActor @Observable
final class FolderEditViewModel {
    enum Mode {
        case create
        case edit(Folder)
    }

    var displayName: String
    var criteriaText: String
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    private let mode: Mode
    private let folderStore: any FolderStoring
    private let onSaved: () -> Void
    private let initialDisplayName: String
    private let initialCriteriaText: String

    var title: String {
        switch mode {
        case .create: "새 폴더"
        case .edit: "폴더 수정"
        }
    }

    var isNameValid: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 취소 확인 여부를 View가 판단하는 데 쓴다(화면설계서: "변경사항이 있으면 버리기 확인").
    var hasUnsavedChanges: Bool {
        displayName != initialDisplayName || criteriaText != initialCriteriaText
    }

    init(mode: Mode, folderStore: any FolderStoring, onSaved: @escaping () -> Void) {
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
                try await folderStore.save(Folder(
                    id: UUID().uuidString, displayName: trimmedName, criteriaText: criteriaTextValue,
                    criteriaVersion: 1, criteriaState: .pending, membershipRevision: 0
                ))
            case .edit(let existing):
                // 이름만 바꾸면 criteriaVersion 그대로, 기준 자체가 바뀌면 올린다 — "이름만 변경하면
                // AI 재분류 요청 없음"(§10.2)과 ERD 의도에 맞춘다. 지금은 이 버전을 실제로 쓰는
                // Job이 없지만, 나중에 생겼을 때 맞는 값이 이미 쌓여있게 지금부터 정확히 올려둔다.
                let criteriaChanged = criteriaTextValue != existing.criteriaText
                try await folderStore.save(Folder(
                    id: existing.id, displayName: trimmedName, criteriaText: criteriaTextValue,
                    criteriaVersion: criteriaChanged ? existing.criteriaVersion + 1 : existing.criteriaVersion,
                    criteriaState: .pending, membershipRevision: existing.membershipRevision
                ))
            }
            onSaved()
        } catch {
            errorMessage = "폴더를 저장하지 못했어요."
        }
    }
}
