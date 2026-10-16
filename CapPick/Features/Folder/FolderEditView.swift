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
            // 시안 "새 폴더" 시트(.sheet): 폴더 아이콘 타일, 회색 입력칸, 가운데 정렬 도움말. 시안에 없는
            // 분류 기준·"기존 캡처에도 적용"은 같은 스타일로 아래에 이어 붙였다(기존 기능 유지).
            ScrollView {
                VStack(spacing: 0) {
                    Image(systemName: "folder")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(AppPalette.text)
                        .frame(width: 66, height: 66)
                        .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(AppPalette.separator, lineWidth: 1)
                        }
                        .padding(.vertical, 20)

                    TextField("폴더 이름", text: $viewModel.displayName)
                        .font(.system(size: 16))
                        .fieldBox(height: 48)
                    Text(viewModel.isCreating ? "캡처를 정리할 새 폴더를 만들어요." : "폴더 이름과 분류 기준을 바꿀 수 있어요.")
                        .font(.system(size: 12))
                        .foregroundStyle(AppPalette.secondary)
                        .padding(.top, 10)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("분류 기준 (선택)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppPalette.text)
                        TextField("예: 맛집·카페 정보, 메뉴판, 가게 위치", text: $viewModel.criteriaText, axis: .vertical)
                            .font(.system(size: 15))
                            .lineLimit(3...6)
                            .padding(.vertical, 12)
                            .fieldBox(height: 96)
                        Text("이 기준으로 새로 분석되는 캡처가 자동으로 분류돼요. 비워두면 폴더 이름을 기준으로 대신 써요.")
                            .font(.system(size: 12))
                            .foregroundStyle(AppPalette.secondary)
                    }
                    .padding(.top, 28)

                    if viewModel.isCreating {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(isOn: $viewModel.applyToExistingCaptures) {
                                Text("기존 캡처에도 적용")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(AppPalette.text)
                            }
                            .tint(AppPalette.text)
                            Text("저장 후 이미 분석된 캡처 중 이 기준에 맞는 것을 찾아 보여줘요.")
                                .font(.system(size: 12))
                                .foregroundStyle(AppPalette.secondary)
                        }
                        .padding(.top, 24)
                    }
                    if let message = viewModel.errorMessage {
                        Text(message).font(.footnote).foregroundStyle(.red).padding(.top, 16)
                    }
                }
                .padding(.horizontal, AppPalette.horizontalPadding)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(viewModel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { handleCancel() }
                        .foregroundStyle(AppPalette.text)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(viewModel.isCreating ? "완료" : "저장") {
                        Task {
                            await viewModel.save()
                            if viewModel.errorMessage == nil { dismiss() }
                        }
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(viewModel.isNameValid ? AppPalette.text : Color(white: 0.67))
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
