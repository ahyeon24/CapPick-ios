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
    private let reclassificationStore: any ReclassificationStoring
    private let reclassificationService: ReclassificationService
    private let usageService: UsageService
    private let appDataDeletionService: AppDataDeletionService

    @State private var isCreatingFolder = false
    @State private var isShowingSettings = false
    @State private var reclassificationTarget: ReclassificationTarget?
    // 화면설계서 §7.1·§7.2 HOME-01 상단 검색. 홈 검색창은 마지막 입력을 유지하는 초안이라
    // @State로 충분하다 — NavigationStack에서 자식을 pop해 돌아와도 이 뷰 자체는 다시 안 만들어져
    // 값이 그대로 남는다. 실행은 pendingSearch를 통해서만 한다(입력마다 검색하지 않음).
    @State private var searchQuery = ""
    @State private var pendingSearch: PendingSearch?

    private struct PendingSearch: Identifiable, Hashable {
        let id = UUID()
        let query: String
    }

    private let cardColumns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    init(
        viewModel: HomeViewModel, captureStore: any CaptureStoring, folderStore: any FolderStoring,
        thumbnailLoader: any ThumbnailLoading, analysisQueueService: AnalysisQueueService,
        searchService: SearchService, reclassificationStore: any ReclassificationStoring,
        reclassificationService: ReclassificationService, usageService: UsageService,
        appDataDeletionService: AppDataDeletionService
    ) {
        _viewModel = State(initialValue: viewModel)
        self.captureStore = captureStore
        self.folderStore = folderStore
        self.thumbnailLoader = thumbnailLoader
        self.analysisQueueService = analysisQueueService
        self.searchService = searchService
        self.reclassificationStore = reclassificationStore
        self.reclassificationService = reclassificationService
        self.usageService = usageService
        self.appDataDeletionService = appDataDeletionService
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("설정")
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsView(viewModel: SettingsViewModel(
                    usageService: usageService, appDataDeletionService: appDataDeletionService))
            }
            .onChange(of: isShowingSettings) { wasShowing, isShowing in
                // 앱 데이터 삭제가 여기서 일어날 수 있다 — 닫히면(특히 삭제 후) 폴더 카드
                // 개수를 새로 고친다.
                if wasShowing, !isShowing {
                    Task { await viewModel.refresh() }
                }
            }
            .task { await viewModel.refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await viewModel.refresh() }
                }
            }
            .onAppear {
                // BROWSE-01/DETAIL-01에서 캡픽 제외 등으로 돌아왔을 때 폴더 카드 개수를 새로
                // 고친다 — pop으로 돌아오는 건 이 뷰를 다시 만들지 않아 .task가 재실행 안 된다.
                Task { await viewModel.refresh() }
            }
            .sheet(isPresented: $isCreatingFolder) {
                FolderEditView(viewModel: FolderEditViewModel(
                    mode: .create, folderStore: folderStore,
                    onSaved: { folder, applyToExisting in
                        Task { await viewModel.refresh() }
                        if applyToExisting {
                            reclassificationTarget = ReclassificationTarget(folder: folder, mode: .initialApply)
                        }
                    }))
            }
            .sheet(item: $reclassificationTarget) { target in
                NavigationStack {
                    ReclassificationView(viewModel: ReclassificationViewModel(
                        folder: target.folder, mode: target.mode, reclassificationService: reclassificationService,
                        reclassificationStore: reclassificationStore, captureStore: captureStore,
                        thumbnailLoader: thumbnailLoader))
                }
                .onDisappear { Task { await viewModel.refresh() } }
            }
            .navigationDestination(item: $pendingSearch) { pending in
                BrowseView(
                    viewModel: BrowseViewModel(
                        scope: .all, captureStore: captureStore, folderStore: folderStore,
                        analysisQueueService: analysisQueueService, searchService: searchService,
                        initialQuery: pending.query),
                    captureStore: captureStore, folderStore: folderStore,
                    analysisQueueService: analysisQueueService, thumbnailLoader: thumbnailLoader
                )
            }
        }
    }

    // 화면설계서 §7.2: "빈 검색어 실행 | 검색 요청 없이 입력 유지".
    private func executeSearch() {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingSearch = PendingSearch(query: trimmed)
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
            searchArea(progress: progress)
            if progress.total > 0 {
                folderCards(total: progress.total)
            }
        } else if let message = viewModel.errorMessage {
            Text(message).foregroundStyle(.red)
        } else {
            ProgressView()
        }
    }

    // 화면설계서 §7.1 HOME-01 상단 큰 영역 — 안내 문구·작은 분석 상태·검색창을 한 덩어리로 둔다.
    // 하단에는 검색창을 두지 않는다(§7.2 "검색창을 하단으로 옮기지 않음").
    @ViewBuilder
    private func searchArea(progress: AnalysisProgress) -> some View {
        Text("어떤 캡처를 찾고 있나요?").font(.title3)
        Text("\(progress.searchReady.formatted()) / \(progress.total.formatted())장 분석 완료")
            .foregroundStyle(.secondary)
        HStack {
            TextField("기억나는 말로 검색", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .onSubmit { executeSearch() }
            Button("검색") { executeSearch() }
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
                    analysisQueueService: analysisQueueService, searchService: searchService,
                    reclassificationStore: reclassificationStore, reclassificationService: reclassificationService
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
                captureStore: captureStore, folderStore: folderStore,
                analysisQueueService: analysisQueueService, thumbnailLoader: thumbnailLoader
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
