import SwiftUI
import UIKit

struct HomeView: View {
    @State private var viewModel: HomeViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    private let captureStore: any CaptureStoring
    private let folderStore: any FolderStoring
    private let thumbnailLoader: any ThumbnailLoading
    private let analysisQueueService: AnalysisQueueService
    private let searchService: SearchService

    @State private var isCreatingFolder = false

    private let cardColumns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    init(
        viewModel: HomeViewModel, captureStore: any CaptureStoring, folderStore: any FolderStoring,
        thumbnailLoader: any ThumbnailLoading, analysisQueueService: AnalysisQueueService,
        searchService: SearchService
    ) {
        _viewModel = State(initialValue: viewModel)
        self.captureStore = captureStore
        self.folderStore = folderStore
        self.thumbnailLoader = thumbnailLoader
        self.analysisQueueService = analysisQueueService
        self.searchService = searchService
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("CapPick").font(.largeTitle.bold())
                    content
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task { await viewModel.refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await viewModel.refresh() }
                }
            }
            .sheet(isPresented: $isCreatingFolder) {
                FolderEditView(viewModel: FolderEditViewModel(
                    mode: .create, folderStore: folderStore, onSaved: { Task { await viewModel.refresh() } }))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !viewModel.authorization.canReadPhotos {
            Text("사진 접근이 필요해요.").font(.title3)
            Text("설정에서 사진 접근을 허용하면 기존 스크린샷을 찾아 정리할 수 있어요.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("설정으로 이동") { openSettings() }
                .buttonStyle(.borderedProminent)
        } else if let progress = viewModel.progress {
            if viewModel.authorization == .limited {
                Text("허용한 사진 중 스크린샷만 보여요. 기존 캡처 전체가 아닐 수 있어요.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text("접근 가능한 스크린샷 \(progress.total.formatted())장").font(.title3)
            Text("\(progress.searchReady.formatted()) / \(progress.total.formatted())장 분석 완료")
                .foregroundStyle(.secondary)
            if progress.total > 0 {
                folderCards(total: progress.total)
            }
        } else if let message = viewModel.errorMessage {
            Text(message).foregroundStyle(.red)
        } else {
            ProgressView()
        }
    }

    // 화면설계서 HOME-01 카드 목록 — 전체·미분류는 시스템 카드(이름 변경·삭제 없음), 그 뒤가
    // 사용자가 만든 폴더들이다. 폴더가 없어도 전체·미분류는 항상 보인다.
    @ViewBuilder
    private func folderCards(total: Int) -> some View {
        LazyVGrid(columns: cardColumns, spacing: 12) {
            folderCard(scope: .all, title: "전체", count: total)
            folderCard(scope: .unclassified, title: "미분류", count: viewModel.unclassifiedCount)
            ForEach(viewModel.folders) { folder in
                folderCard(scope: .folder(folder), title: folder.displayName, count: viewModel.count(for: folder))
            }
        }
        HStack {
            NavigationLink("관리") {
                FolderListView(
                    captureStore: captureStore, folderStore: folderStore, thumbnailLoader: thumbnailLoader,
                    analysisQueueService: analysisQueueService, searchService: searchService
                )
            }
            Spacer()
            Button("+ 새 폴더") { isCreatingFolder = true }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func folderCard(scope: BrowseScope, title: String, count: Int) -> some View {
        NavigationLink {
            BrowseView(
                viewModel: BrowseViewModel(
                    scope: scope, captureStore: captureStore, folderStore: folderStore,
                    analysisQueueService: analysisQueueService, searchService: searchService),
                thumbnailLoader: thumbnailLoader
            )
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Spacer()
                Text(title).font(.headline).foregroundStyle(.primary)
                Text("\(count.formatted())장").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(height: 90, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }
}
