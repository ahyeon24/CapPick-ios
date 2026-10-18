import SwiftUI

// 화면설계서 §9 DETAIL-01. 2026-10-17 사용자 요청으로 사진 앱 갤러리처럼 바꿨다:
// - 사진 한 장을 화면에 맞춰 보여주고 위아래 스크롤은 없다.
// - 옆으로 넘기면 들어온 목록(검색 결과·폴더)의 이전·다음 캡처로 넘어간다.
// - 상단: 즐겨찾기 · ⓘ(분석 상태·소속 폴더를 아래에서 올라오는 시트로) · ···(공유, 폴더로 이동,
//   다시 분석하기, 캡픽에서 제외).
struct CaptureDetailView: View {
    private let captures: [Capture]
    private let captureStore: any CaptureStoring
    private let folderStore: any FolderStoring
    private let analysisQueueService: AnalysisQueueService
    private let thumbnailLoader: any ThumbnailLoading
    private let sourceFolderID: String?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String
    /// 넘겨 본 캡처마다 뷰모델을 하나씩 만들어 둔다 — 다시 돌아와도 불러온 원본·상태를 그대로 쓴다.
    @State private var cache = ViewModelCache()
    @State private var isInfoPresented = false
    @State private var isShareSheetPresented = false
    @State private var isExcludeConfirmationPresented = false
    /// 폴더로 옮긴 뒤 잠깐 보여주는 안내.
    @State private var moveNotice: String?

    init(
        captures: [Capture], initialCaptureID: String, captureStore: any CaptureStoring,
        folderStore: any FolderStoring, analysisQueueService: AnalysisQueueService,
        thumbnailLoader: any ThumbnailLoading, sourceFolderID: String? = nil
    ) {
        self.captures = captures
        self.sourceFolderID = sourceFolderID
        self.captureStore = captureStore
        self.folderStore = folderStore
        self.analysisQueueService = analysisQueueService
        self.thumbnailLoader = thumbnailLoader
        _selectedID = State(initialValue: initialCaptureID)
    }

    var body: some View {
        TabView(selection: $selectedID) {
            ForEach(captures) { capture in
                CaptureDetailPage(viewModel: viewModel(for: capture), cache: cache)
                    .tag(capture.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Color(.systemBackground))
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(isPresented: $isInfoPresented) {
            CaptureInfoSheet(viewModel: currentViewModel)
                .presentationDetents([.height(220)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isShareSheetPresented) {
            if let image = currentViewModel.fullImage {
                ActivityView(activityItems: [image])
            }
        }
        .alert("캡픽에서 제외할까요?", isPresented: $isExcludeConfirmationPresented) {
            Button("제외", role: .destructive) { Task { await currentViewModel.exclude() } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("캡픽의 목록과 검색에서 제외돼요. 사진 앱의 원본은 유지돼요.")
        }
        .onChange(of: currentViewModel.didExclude) { _, didExclude in
            if didExclude { dismiss() }
        }
        .overlay(alignment: .bottom) {
            if let moveNotice {
                Text(moveNotice)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(AppPalette.text, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: moveNotice)
        .onChange(of: selectedID) { _, _ in prefetchNeighbors() }
        .task { prefetchNeighbors() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        let current = currentViewModel
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                Task { await current.toggleFavorite() }
            } label: {
                Image(systemName: current.capture.favorite ? "star.fill" : "star")
            }
            .accessibilityLabel(current.capture.favorite ? "즐겨찾기 해제" : "즐겨찾기")

            Button {
                isInfoPresented = true
            } label: {
                Image(systemName: "info.circle")
            }
            .accessibilityLabel("정보")

            Menu {
                Button("공유", systemImage: "square.and.arrow.up") { isShareSheetPresented = true }
                    .disabled(current.fullImage == nil)
                SwiftUI.Menu {
                    if current.allFolders.isEmpty {
                        Text("만든 폴더가 없어요")
                    }
                    ForEach(current.allFolders) { folder in
                        let isMember = current.folders.contains { $0.id == folder.id }
                        Button {
                            Task { await move(current, to: folder) }
                        } label: {
                            if isMember {
                                Label(folder.displayName, systemImage: "checkmark")
                            } else {
                                Text(folder.displayName)
                            }
                        }
                        .disabled(isMember)
                    }
                } label: {
                    Label("폴더로 이동", systemImage: "folder")
                }
                // pending(자동 큐가 곧 처리)·processing(진행 중)은 뺀다 — 실패했을 때뿐 아니라 이미
                // 성공한 캡처도 원하면 다시 돌릴 수 있다(2026-09-25 사용자 결정).
                if current.capture.searchState == .failed || current.capture.searchState == .ready {
                    Button("다시 분석하기", systemImage: "arrow.clockwise") {
                        Task { await current.retry() }
                    }
                    .disabled(current.isRetrying)
                }
                Button("캡픽에서 제외", systemImage: "eye.slash", role: .destructive) {
                    isExcludeConfirmationPresented = true
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("더보기")
        }
    }

    private func move(_ model: CaptureDetailViewModel, to folder: Folder) async {
        await model.move(to: folder)
        guard model.errorMessage == nil else {
            moveNotice = "폴더를 옮기지 못했어요"
            return
        }
        moveNotice = "'\(folder.displayName)' 폴더로 옮겼어요"
        try? await Task.sleep(for: .seconds(2))
        moveNotice = nil
    }

    /// 지금 보는 사진의 앞뒤 한 장씩을 미리 불러 둔다 — 넘기는 순간 이미 준비돼 있게(2026-10-17).
    private func prefetchNeighbors() {
        guard let index = captures.firstIndex(where: { $0.id == selectedID }) else { return }
        for neighbor in [index - 1, index + 1] where captures.indices.contains(neighbor) {
            let model = viewModel(for: captures[neighbor])
            let size = cache.displayPixelSize
            Task { await model.load(fitting: size) }
        }
    }

    private var currentViewModel: CaptureDetailViewModel {
        let capture = captures.first { $0.id == selectedID } ?? captures[0]
        return viewModel(for: capture)
    }

    private func viewModel(for capture: Capture) -> CaptureDetailViewModel {
        cache.model(for: capture) {
            CaptureDetailViewModel(
                capture: capture, captureStore: captureStore, folderStore: folderStore,
                analysisQueueService: analysisQueueService, thumbnailLoader: thumbnailLoader,
                sourceFolderID: sourceFolderID)
        }
    }
}

/// body를 그리는 중에 만들어도 화면을 다시 그리게 하지 않는 단순 캐시(관찰 대상이 아님).
@MainActor
private final class ViewModelCache {
    private var models: [String: CaptureDetailViewModel] = [:]
    /// 사진을 그릴 영역의 픽셀 크기 — 첫 페이지가 화면에 나타날 때 정해지고, 미리 불러오기도 이 크기로.
    var displayPixelSize: CGSize?

    func model(for capture: Capture, make: () -> CaptureDetailViewModel) -> CaptureDetailViewModel {
        if let existing = models[capture.id] { return existing }
        let created = make()
        models[capture.id] = created
        return created
    }
}

/// 한 장. 화면에 맞춰 보여주고(스크롤 없음), 핀치로 잠깐 확대할 수 있다. 글자는 Live Text로 길게
/// 눌러 바로 선택·복사한다(DETAIL-03).
private struct CaptureDetailPage: View {
    let viewModel: CaptureDetailViewModel
    let cache: ViewModelCache
    @Environment(\.displayScale) private var displayScale
    @State private var zoomScale: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            content
                .frame(width: proxy.size.width, height: proxy.size.height)
                .task {
                    // 화면 크기만큼만 받는다(픽셀 단위). 원본이 더 작으면 원본 그대로 온다.
                    let size = CGSize(width: proxy.size.width * displayScale, height: proxy.size.height * displayScale)
                    if cache.displayPixelSize == nil { cache.displayPixelSize = size }
                    await viewModel.load(fitting: size)
                }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if let image = viewModel.fullImage {
                // LiveTextImageView(UIKit)라 제스처를 바깥 프레임에 건다 — 안쪽 Live Text의 길게 누르기와
                // 겹치지 않게.
                LiveTextImageView(image: image)
                    .aspectRatio(image.size, contentMode: .fit)
                    .scaleEffect(zoomScale)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { zoomScale = max($0, 1) }
                            .onEnded { _ in withAnimation { zoomScale = 1 } }
                    )
            } else if let preview = viewModel.previewImage {
                // 원본이 오기 전 — 작은 이미지를 먼저 보여준다(글자 선택은 원본이 온 뒤부터).
                Image(uiImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if viewModel.isLoadingImage {
                ProgressView()
            } else {
                Text("원본을 준비하지 못했어요.")
                    .font(.system(size: 14))
                    .foregroundStyle(AppPalette.secondary)
            }
        }
    }
}

/// ⓘ를 누르면 아래에서 올라오는 정보 시트 — 분석 상태와 소속 폴더(DETAIL-02).
private struct CaptureInfoSheet: View {
    let viewModel: CaptureDetailViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("정보")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(AppPalette.text)
            row(title: "분석 상태", value: statusText)
            row(title: "폴더", value: viewModel.folders.isEmpty
                ? "미분류" : viewModel.folders.map(\.displayName).joined(separator: ", "))
            if viewModel.isRetrying {
                Label("다시 분석하는 중", systemImage: "arrow.clockwise")
                    .font(.system(size: 13))
                    .foregroundStyle(AppPalette.secondary)
            }
            if let message = viewModel.errorMessage {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppPalette.horizontalPadding)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(AppPalette.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppPalette.text)
        }
    }

    // DETAIL-02. 미분석·실패·분류 보류를 구분한다 — 검색용 내부 정보(searchText 등)는 보여주지 않는다.
    private var statusText: String {
        switch viewModel.capture.searchState {
        case .pending: "분석 대기 중"
        case .processing: "분석 중"
        case .failed: "분석 실패"
        case .ready:
            switch viewModel.capture.classificationState {
            case .pending, .processing: "분류 중"
            case .complete: "분석 완료"
            case .failed, .blocked: "분류 보류"
            }
        }
    }
}

// 이 앱 첫 공유 시트 — UIActivityViewController를 그대로 감싼다.
private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
