import SwiftUI

// 화면설계서 BROWSE-01. 2026-10-14부터 §7.3대로 이미지 비율에 따라 높이가 다른 2열 배치다
// (전에는 정사각형 균일 그리드). 화면 안에서 폴더를 바로 전환하는 가로 스크롤 줄(§7.3)은 이번엔 없다 —
// 폴더 전환은 Home/FOLDER-01로 돌아가 다시 들어가는 것으로 대신한다. 정렬 옵션도 아직 없다
// (항상 관련도순 또는 최근순).
struct BrowseView: View {
    @State private var viewModel: BrowseViewModel
    private let captureStore: any CaptureStoring
    private let folderStore: any FolderStoring
    private let analysisQueueService: AnalysisQueueService
    private let thumbnailLoader: any ThumbnailLoading


    init(
        viewModel: BrowseViewModel, captureStore: any CaptureStoring, folderStore: any FolderStoring,
        analysisQueueService: AnalysisQueueService, thumbnailLoader: any ThumbnailLoading
    ) {
        _viewModel = State(initialValue: viewModel)
        self.captureStore = captureStore
        self.folderStore = folderStore
        self.analysisQueueService = analysisQueueService
        self.thumbnailLoader = thumbnailLoader
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        ScrollView {
            if viewModel.captures.isEmpty, !viewModel.isLoading {
                Text(emptyStateMessage)
                    .foregroundStyle(.secondary)
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
                .padding(.top, Self.gridSpacing)
            }
            if viewModel.isLoading {
                ProgressView().padding(.top, 24)
            }
            if let message = viewModel.errorMessage {
                Text(message).foregroundStyle(.red).padding(.top, 24)
            }
        }
        .navigationTitle(navigationTitle)
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

    /// 검색 중이면 몇 장을 찾았는지까지 보여준다 — 무엇을 찾은 결과인지는 하단 검색창에 남아 있다.
    private var navigationTitle: String {
        guard viewModel.isSearchActive else { return viewModel.scope.title }
        return viewModel.isLoading ? "검색 중" : "검색 결과 \(viewModel.captures.count)장"
    }

    private func masonryColumn(_ indices: [Int], captures: [Capture], ratios: [Double]) -> some View {
        LazyVStack(spacing: Self.gridSpacing) {
            ForEach(indices, id: \.self) { index in
                let capture = captures[index]
                        NavigationLink {
                            CaptureDetailView(viewModel: CaptureDetailViewModel(
                                capture: capture, captureStore: captureStore, folderStore: folderStore,
                                analysisQueueService: analysisQueueService, thumbnailLoader: thumbnailLoader
                            ))
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
            }
        }
    }

    private var emptyStateMessage: String {
        viewModel.isSearchActive ? "관련 캡처를 찾지 못했어요." : "아직 접근 가능한 캡처가 없어요."
    }

    @ViewBuilder
    private func searchBar(viewModel: Bindable<BrowseViewModel>) -> some View {
        HStack {
            TextField("기억나는 말로 검색", text: viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await self.viewModel.search() } }
                .onChange(of: viewModel.searchText.wrappedValue) { _, newValue in
                    // 입력할 때마다 검색을 부르지 않는다 — 검색어를 완전히 지웠을 때만 로컬로 되돌아간다.
                    if newValue.isEmpty {
                        Task { await self.viewModel.clearSearch() }
                    }
                }
            Button("검색") { Task { await self.viewModel.search() } }
        }
        .padding()
        .background(.bar)
    }
}
