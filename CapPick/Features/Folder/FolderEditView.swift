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
                    Text("이 기준으로 새로 분석되는 캡처가 자동으로 분류돼요. 비워두면 폴더 이름을 기준으로 대신 써요.")
                }
                if viewModel.isCreating {
                    Section {
                        Toggle("기존 캡처에도 적용", isOn: $viewModel.applyToExistingCaptures)
                    } footer: {
                        Text("저장 후 이미 분석된 캡처 중 이 기준에 맞는 것을 찾아 보여줘요.")
                    }
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
