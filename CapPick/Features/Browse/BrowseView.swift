import SwiftUI

// 화면설계서 BROWSE-01 중 "빈 검색어" 상태만. 검색창·폴더 전환·정렬 등은 아직 없다.
struct BrowseView: View {
    @State private var viewModel: BrowseViewModel
    private let thumbnailLoader: any ThumbnailLoading

    private let columns = [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)]

    init(viewModel: BrowseViewModel, thumbnailLoader: any ThumbnailLoading) {
        _viewModel = State(initialValue: viewModel)
        self.thumbnailLoader = thumbnailLoader
    }

    var body: some View {
        ScrollView {
            if viewModel.captures.isEmpty, !viewModel.isLoading {
                Text("아직 접근 가능한 캡처가 없어요.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 48)
            } else {
                // LazyVGrid라 스크롤에 따라 썸네일을 늦게 불러온다 — 한 번에 원본을 전부 안 불러온다(§7.5).
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(viewModel.captures) { capture in
                        CaptureThumbnailView(capture: capture, thumbnailLoader: thumbnailLoader)
                    }
                }
            }
            if let message = viewModel.errorMessage {
                Text(message).foregroundStyle(.red).padding(.top, 24)
            }
        }
        .navigationTitle("전체")
        .task { await viewModel.load() }
    }
}
