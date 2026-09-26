import SwiftUI

struct SettingsView: View {
    @State var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                Section("사용량") {
                    if viewModel.isLoadingUsage {
                        ProgressView()
                    } else if viewModel.usageLoadFailed {
                        Text("사용량을 불러오지 못했어요.")
                            .foregroundStyle(.secondary)
                    } else if let usage = viewModel.usage {
                        ForEach(usage.categories, id: \.category) { category in
                            usageRow(category)
                        }
                    }
                }

                Section {
                    Button("앱 데이터 삭제", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                    .disabled(viewModel.isDeletingData)
                } footer: {
                    Text("분석·검색·폴더 데이터가 모두 사라져요. 사진 원본은 그대로 있어요. 이후엔 처음 시작하는 것처럼 다시 정리해야 해요.")
                }

                if let deletionError = viewModel.deletionError {
                    Text(deletionError)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("설정")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
            .overlay {
                if viewModel.isDeletingData {
                    ProgressView("삭제하는 중…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert("앱 데이터를 삭제할까요?", isPresented: $showDeleteConfirmation) {
                Button("취소", role: .cancel) {}
                Button("삭제", role: .destructive) {
                    Task { await viewModel.deleteAllData() }
                }
            } message: {
                Text("분석·검색·폴더 데이터가 모두 사라져요. 사진 원본은 그대로 있어요.")
            }
            .task { await viewModel.load() }
            .onChange(of: viewModel.didDeleteData) { _, didDelete in
                if didDelete { dismiss() }
            }
        }
    }

    private func usageRow(_ category: UsageCategorySummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title(for: category.category))
                .font(.body)
            Text("완료 \(category.usedUnits)건 · 대기 \(category.reservedUnits)건")
                .font(.footnote)
                .foregroundStyle(.secondary)
            // limitUnits·resetsAt은 한도 정책이 미정이면 서버가 null로 내려준다 — 그럴 땐
            // 정해지지 않은 값을 표시하지 않는다(화면설계서 §12).
            if let limitUnits = category.limitUnits {
                Text("한도 \(limitUnits)건")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func title(for category: RemoteUsageCategory) -> String {
        switch category {
        case .contentAnalysis: "캡처 분석"
        case .classification: "자동 분류"
        }
    }
}
