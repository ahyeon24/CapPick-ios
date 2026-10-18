import SwiftUI

// 화면설계서 §11 RECLASS-01 재분류 확인. 변경된 기준, 자동 추가 예정, 자동 제거 예정을 보여주고
// 사용자 확인 후에만 실제 소속에 반영한다 — 확인 전까지는 아무 것도 안 바뀐다. 계산은
// ReclassificationCoordinator가 하므로 이 화면을 닫아도 멈추지 않는다.
struct ReclassificationView: View {
    @State private var viewModel: ReclassificationViewModel
    @Environment(\.dismiss) private var dismiss

    init(viewModel: ReclassificationViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        List {
            Section {
                Text(headline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if viewModel.isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView(viewModel.progressText.map { "판정 중이에요… \($0)" } ?? "판정 중이에요…")
                        Spacer()
                    }
                }
            } else {
                if !viewModel.toAdd.isEmpty {
                    Section("자동 추가 예정 (\(viewModel.toAdd.count)장)") {
                        ForEach(viewModel.toAdd) { item in
                            ReclassificationRow(item: item, thumbnailLoader: viewModel.thumbnailLoader)
                        }
                    }
                }
                if !viewModel.toRemove.isEmpty {
                    Section("자동 제거 예정 (\(viewModel.toRemove.count)장)") {
                        ForEach(viewModel.toRemove) { item in
                            ReclassificationRow(item: item, thumbnailLoader: viewModel.thumbnailLoader)
                        }
                    }
                }
            }

            if let message = viewModel.errorMessage {
                Section {
                    Text(message).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("재분류 확인")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                // 계산 중에 닫으면 계속 돌고(나중에 다시 열면 결과가 보인다), 결과가 나온 뒤 닫으면 버린다.
                Button(viewModel.isLoading ? "닫기" : "적용 안 함") {
                    if viewModel.isLoading {
                        dismiss()
                    } else {
                        Task { await viewModel.discard() }
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await viewModel.confirm() }
                } label: {
                    if viewModel.isApplying {
                        ProgressView()
                    } else {
                        Text("적용")
                    }
                }
                .disabled(viewModel.isLoading || viewModel.isApplying || (viewModel.toAdd.isEmpty && viewModel.toRemove.isEmpty))
            }
        }
        .onChange(of: viewModel.didFinish) { _, didFinish in
            if didFinish { dismiss() }
        }
        .onAppear { viewModel.start() }
        .task(id: viewModel.phase) { await viewModel.phaseChanged() }
    }

    private var headline: String {
        switch viewModel.mode {
        case .initialApply:
            "\"\(viewModel.folder.displayName)\" 기준에 맞는 기존 캡처를 찾고 있어요. 사용자 직접 추가·제거 기록은 그대로 유지돼요."
        case .reclassify:
            "바뀐 분류 기준으로 기존 캡처를 다시 판단해요. 창을 닫아도 계속 판단하고, 다시 열면 결과를 확인할 수 있어요. 사용자 직접 추가·제거 기록은 그대로 유지돼요."
        }
    }
}

private struct ReclassificationRow: View {
    let item: ReclassificationViewModel.PreviewItem
    let thumbnailLoader: any ThumbnailLoading
    @State private var image: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            if let evidence = item.evidence, !evidence.isEmpty {
                Text(evidence)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text("판정 근거 없음")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .task {
            image = await thumbnailLoader.thumbnail(for: item.capture.photoAssetID, targetSize: CGSize(width: 88, height: 88))
        }
    }
}
