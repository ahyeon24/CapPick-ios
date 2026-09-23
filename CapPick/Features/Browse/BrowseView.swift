import SwiftUI

// 화면설계서 BROWSE-01. 화면 안에서 폴더를 바로 전환하는 가로 스크롤 줄(§7.3)은 이번엔 없다 —
// 폴더 전환은 Home/FOLDER-01로 돌아가 다시 들어가는 것으로 대신한다. 정렬 옵션도 아직 없다
// (항상 관련도순 또는 최근순).
struct BrowseView: View {
    @State private var viewModel: BrowseViewModel
    private let thumbnailLoader: any ThumbnailLoading

    private let columns = [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)]

    init(viewModel: BrowseViewModel, thumbnailLoader: any ThumbnailLoading) {
        _viewModel = State(initialValue: viewModel)
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
                // LazyVGrid라 스크롤에 따라 썸네일을 늦게 불러온다 — 한 번에 원본을 전부 안 불러온다(§7.5).
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(viewModel.captures) { capture in
                        CaptureThumbnailView(
                            capture: capture,
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
                }
            }
            if viewModel.isLoading {
                ProgressView().padding(.top, 24)
            }
            if let message = viewModel.errorMessage {
                Text(message).foregroundStyle(.red).padding(.top, 24)
            }
        }
        .navigationTitle(viewModel.isSearchActive ? "검색 결과" : viewModel.scope.title)
        .safeAreaInset(edge: .bottom) {
            searchBar(viewModel: $viewModel)
        }
        .task {
            await viewModel.load()
            await viewModel.observeQueueUntilIdle()
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
