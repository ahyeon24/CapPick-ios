import SwiftUI

// 화면설계서 BROWSE-01. 2026-10-14부터 §7.3대로 이미지 비율에 따라 높이가 다른 2열 배치다
// (전에는 정사각형 균일 그리드). 화면 안에서 폴더를 바로 전환하는 가로 스크롤 줄(§7.3)은 이번엔 없다 —
// 폴더 전환은 Home/FOLDER-01로 돌아가 다시 들어가는 것으로 대신한다. 정렬 옵션도 아직 없다
// (항상 관련도순 또는 최근순).
/// 사용자 폴더 화면의 ··· 관리 메뉴에 필요한 것. 넘기지 않으면(전체·미분류·검색) 메뉴가 없다.
struct BrowseFolderManagement {
    let reclassificationService: ReclassificationService
    let reclassificationStore: any ReclassificationStoring
}

struct BrowseView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: BrowseViewModel
    @State private var editingFolder: Folder?
    @State private var reclassificationTarget: ReclassificationTarget?
    @State private var folderPendingDeletion: Folder?
    private let folderManagement: BrowseFolderManagement?
    private let captureStore: any CaptureStoring
    private let folderStore: any FolderStoring
    private let analysisQueueService: AnalysisQueueService
    private let thumbnailLoader: any ThumbnailLoading


    init(
        viewModel: BrowseViewModel, captureStore: any CaptureStoring, folderStore: any FolderStoring,
        analysisQueueService: AnalysisQueueService, thumbnailLoader: any ThumbnailLoading,
        folderManagement: BrowseFolderManagement? = nil
    ) {
        _viewModel = State(initialValue: viewModel)
        self.folderManagement = folderManagement
        self.captureStore = captureStore
        self.folderStore = folderStore
        self.analysisQueueService = analysisQueueService
        self.thumbnailLoader = thumbnailLoader
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        ScrollView {
            header
            if viewModel.captures.isEmpty, !viewModel.isLoading {
                Text(emptyStateMessage)
                    .font(.system(size: 14))
                    .foregroundStyle(AppPalette.secondary)
                    .padding(.top, 48)
            } else {
                // §7.3 이미지 비율에 따라 높이가 다른 2열 배치(MasonryLayout). 각 열이 LazyVStack이라
                // 스크롤에 따라 썸네일을 늦게 불러온다 — 한 번에 원본을 전부 안 불러온다(§7.5).
                let captures = viewModel.captures
                let ratios = captures.map { MasonryLayout.heightRatio(width: $0.width, height: $0.height) }
                let layout = MasonryLayout.columns(heightRatios: ratios)
                HStack(alignment: .top, spacing: Self.gridSpacing) {
                    masonryColumn(layout.left, captures: captures, ratios: ratios)
                    masonryColumn(layout.right, captures: captures, ratios: ratios)
                }
                .padding(.horizontal, Self.gridSpacing)
            }
            if viewModel.isLoading {
                ProgressView().padding(.top, 24)
            }
            if let message = viewModel.errorMessage {
                Text(message).foregroundStyle(.red).padding(.top, 24)
            }
        }
        .background(Color(.systemBackground))
        // 시안(폴더 상세 화면): 바에는 뒤로 가기와 ··· 만 두고, 제목은 아래 큰 글씨로 보여준다.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if folderManagement != nil, case .folder(let folder) = viewModel.scope {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("이름 변경", systemImage: "pencil") { editingFolder = folder }
                        Button("분류 기준 수정", systemImage: "line.3.horizontal.decrease") { editingFolder = folder }
                        Button("기존 캡처 재분류", systemImage: "arrow.triangle.2.circlepath") {
                            reclassificationTarget = ReclassificationTarget(folder: folder, mode: .reclassify)
                        }
                        Button("폴더 삭제", systemImage: "trash", role: .destructive) { folderPendingDeletion = folder }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(AppPalette.text)
                    }
                    .accessibilityLabel("폴더 관리")
                }
            }
        }
        .sheet(item: $editingFolder) { folder in
            FolderEditView(viewModel: FolderEditViewModel(
                mode: .edit(folder), folderStore: folderStore,
                onSaved: { _, _ in Task { await viewModel.refreshFolder() } }))
        }
        .sheet(item: $reclassificationTarget) { target in
            if let folderManagement {
                NavigationStack {
                    ReclassificationView(viewModel: ReclassificationViewModel(
                        folder: target.folder, mode: target.mode,
                        reclassificationService: folderManagement.reclassificationService,
                        reclassificationStore: folderManagement.reclassificationStore,
                        captureStore: captureStore, thumbnailLoader: thumbnailLoader))
                }
                .onDisappear { Task { await viewModel.load() } }
            }
        }
        .alert(
            "폴더를 삭제할까요?",
            isPresented: Binding(get: { folderPendingDeletion != nil }, set: { if !$0 { folderPendingDeletion = nil } })
        ) {
            Button("삭제", role: .destructive) {
                if let folder = folderPendingDeletion {
                    Task {
                        try? await folderStore.delete(id: folder.id)
                        dismiss() // 지금 보고 있는 폴더가 없어졌으니 홈으로 돌아간다.
                    }
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("폴더만 삭제돼요. 원본 캡처와 다른 폴더 소속은 유지돼요.")
        }
        .safeAreaInset(edge: .bottom) {
            searchBar(viewModel: $viewModel)
        }
        .task {
            // HOME-01 상단 검색에서 이미 검색어를 갖고 들어왔으면(§2 흐름) load() 대신 바로 검색을
            // 실행한다 — 빈 목록이 잠깐 보였다가 검색 결과로 바뀌는 깜빡임을 피한다.
            if viewModel.searchText.isEmpty {
                await viewModel.load()
            } else {
                await viewModel.search()
            }
            await viewModel.observeQueueUntilIdle()
        }
        .onAppear {
            // 상세 화면에서 캡픽 제외 등으로 돌아왔을 때 목록을 새로고침한다 — NavigationStack에서
            // 자식을 pop해 돌아오는 건 이 뷰를 다시 만들지 않아서 .task가 재실행되지 않는다.
            // 검색 결과를 보여주는 중이면 load()로 덮어쓰지 않는다 — "뒤로 가면 검색어·폴더·
            // 스크롤 위치 복원"(화면설계서 §2)을 지킨다.
            guard !viewModel.isSearchActive else { return }
            Task { await viewModel.load() }
        }
    }

    /// 카드 사이·화면 가장자리 여백. 핀터레스트처럼 카드가 서로 떨어져 보이게(2026-10-14 사용자 요청).
    private static let gridSpacing: CGFloat = 8

    /// 시안 .detail-header — 큰 제목(32) + 보조 한 줄(13). 검색 중이면 제목이 검색어가 된다.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(viewModel.isSearchActive ? "“\(viewModel.activeQuery)”" : viewModel.scope.title)
                .font(AppPalette.title(32))
                .tracking(-1)
                .foregroundStyle(AppPalette.text)
                .lineLimit(2)
            Text(headerSubtitle)
                .font(.system(size: 13))
                .foregroundStyle(AppPalette.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppPalette.horizontalPadding)
        .padding(.top, 7)
        .padding(.bottom, 20)
    }

    private var headerSubtitle: String {
        if viewModel.isLoading { return viewModel.isSearchActive ? "찾는 중" : " " }
        let count = viewModel.captures.count.formatted()
        if viewModel.isSearchActive {
            let scopeNote = viewModel.scope == .all ? "" : "\(viewModel.scope.title)에서 "
            return "\(scopeNote)\(count)장 찾았어요"
        }
        return "\(count)장의 캡처"
    }

    private func masonryColumn(_ indices: [Int], captures: [Capture], ratios: [Double]) -> some View {
        LazyVStack(spacing: Self.gridSpacing) {
            // 칸은 반드시 캡처 ID로 구분한다 — 인덱스로 구분하면 검색 결과가 바뀌어도 같은 자리의
            // 칸이 재사용돼 이전 목록의 썸네일이 그대로 남는다(2026-10-15 실제로 겪은 버그).
            ForEach(indices, id: \.self) { index in
                let capture = captures[index]
                        NavigationLink {
                            // 지금 보이는 목록 순서 그대로 옆으로 넘겨 볼 수 있게 목록 전체를 넘긴다.
                            CaptureDetailView(
                                captures: captures, initialCaptureID: capture.id,
                                captureStore: captureStore, folderStore: folderStore,
                                analysisQueueService: analysisQueueService, thumbnailLoader: thumbnailLoader)
                        } label: {
                            CaptureThumbnailView(
                                capture: capture,
                                heightRatio: ratios[index],
                                thumbnailLoader: thumbnailLoader,
                                isAnalyzing: viewModel.analyzingCaptureIDs.contains(capture.id),
                                onRetryTapped: { Task { await viewModel.retry(capture) } },
                                folders: viewModel.folders,
                                onAddToFolder: { folder in Task { await viewModel.addToFolder(capture, folderID: folder.id) } },
                                onRemoveFromCurrentFolder: viewModel.scope.folderID == nil
                                    ? nil
                                    : { Task { await viewModel.removeFromCurrentFolder(capture) } }
                            )
                        }
                        .buttonStyle(.plain)
                        .id(capture.id)
            }
        }
    }

    private var emptyStateMessage: String {
        viewModel.isSearchActive ? "관련 캡처를 찾지 못했어요." : "아직 접근 가능한 캡처가 없어요."
    }

    @ViewBuilder
    private func searchBar(viewModel: Bindable<BrowseViewModel>) -> some View {
        // 홈 검색창과 같은 회색 상자. 별도 "검색" 버튼 없이 키보드 검색 키로 실행한다.
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(AppPalette.text)
            TextField("기억나는 말로 검색", text: viewModel.searchText)
                .font(.system(size: 15))
                .submitLabel(.search)
                .onSubmit { Task { await self.viewModel.search() } }
                .onChange(of: viewModel.searchText.wrappedValue) { _, newValue in
                    // 입력할 때마다 검색을 부르지 않는다 — 검색어를 완전히 지웠을 때만 로컬로 되돌아간다.
                    if newValue.isEmpty {
                        Task { await self.viewModel.clearSearch() }
                    }
                }
            if !viewModel.searchText.wrappedValue.isEmpty {
                Button {
                    Task { await self.viewModel.clearSearch() }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(AppPalette.secondary)
                }
                .accessibilityLabel("검색어 지우기")
            }
        }
        .fieldBox(height: 44)
        .padding(.horizontal, AppPalette.horizontalPadding)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
        .overlay(alignment: .top) { AppPalette.separator.frame(height: 1) }
    }
}
