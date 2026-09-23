import SwiftUI

// 화면설계서 FOLDER-02 생성·수정 시트.
struct FolderEditView: View {
    @State private var viewModel: FolderEditViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsDiscardConfirmation = false

    init(viewModel: FolderEditViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        NavigationStack {
            Form {
                Section("폴더 이름") {
                    TextField("이름", text: $viewModel.displayName)
                }
                Section {
                    TextEditor(text: $viewModel.criteriaText)
                        .frame(minHeight: 100)
                } header: {
                    Text("분류 기준 (선택)")
                } footer: {
                    Text("나중에 자동 분류 기능이 생기면 이 기준으로 캡처를 판단해요. 지금은 참고용으로만 저장돼요.")
                }
                if let message = viewModel.errorMessage {
                    Text(message).foregroundStyle(.red)
                }
            }
            .navigationTitle(viewModel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { handleCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        Task {
                            await viewModel.save()
                            if viewModel.errorMessage == nil { dismiss() }
                        }
                    }
                    .disabled(!viewModel.isNameValid || viewModel.isSaving)
                }
            }
            .confirmationDialog(
                "변경사항을 버릴까요?", isPresented: $showsDiscardConfirmation, titleVisibility: .visible
            ) {
                Button("버리기", role: .destructive) { dismiss() }
                Button("계속 편집", role: .cancel) {}
            }
        }
    }

    private func handleCancel() {
        if viewModel.hasUnsavedChanges {
            showsDiscardConfirmation = true
        } else {
            dismiss()
        }
    }
}
