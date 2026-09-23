import SwiftUI

// 화면설계서 §9 DETAIL-01. 상단: 뒤로(NavigationStack 기본 제공)·즐겨찾기·더보기.
struct CaptureDetailView: View {
    @State private var viewModel: CaptureDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var zoomScale: CGFloat = 1
    @State private var isShareSheetPresented = false
    @State private var isExcludeConfirmationPresented = false

    init(viewModel: CaptureDetailViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        ScrollView {
            imageSection
            VStack(alignment: .leading, spacing: 16) {
                statusSection
                foldersSection
                if viewModel.capture.searchState == .failed {
                    retrySection
                }
                if let message = viewModel.errorMessage {
                    Text(message).foregroundStyle(.red).font(.footnote)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("캡처")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await viewModel.toggleFavorite() }
                } label: {
                    Image(systemName: viewModel.capture.favorite ? "star.fill" : "star")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("공유", systemImage: "square.and.arrow.up") { isShareSheetPresented = true }
                        .disabled(viewModel.fullImage == nil)
                    Button("캡픽에서 제외", systemImage: "eye.slash", role: .destructive) {
                        isExcludeConfirmationPresented = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $isShareSheetPresented) {
            if let image = viewModel.fullImage {
                ActivityView(activityItems: [image])
            }
        }
        .alert("캡픽에서 제외할까요?", isPresented: $isExcludeConfirmationPresented) {
            Button("제외", role: .destructive) { Task { await viewModel.exclude() } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("캡픽의 목록과 검색에서 제외돼요. 사진 앱의 원본은 유지돼요.")
        }
        .onChange(of: viewModel.didExclude) { _, didExclude in
            if didExclude { dismiss() }
        }
        .task { await viewModel.load() }
    }

    // 정교한 핀치줌+팬은 아니다 — 기본 스케일 제스처 + 세로 스크롤(긴 스크린샷 대응)만.
    // 화면설계서 §7.3: "긴 캡처에는 최대 높이와 전체 보기 단서" 같은 정밀한 처리는 다음 단계.
    // LiveTextImageView(UIKit 기반)라 SwiftUI 제스처를 이미지 자체가 아니라 바깥 프레임에 건다 —
    // 안쪽 ImageAnalysisInteraction의 길게 누르기(텍스트 선택)와 겹치지 않게.
    @ViewBuilder
    private var imageSection: some View {
        if let image = viewModel.fullImage {
            // LiveTextImageView.sizeThatFits(...)가 SwiftUI가 제안한 크기를 그대로 쓰게 했으니
            // 여기서는 일반 Image처럼 .aspectRatio만으로 화면 너비에 맞게 줄어든다.
            LiveTextImageView(image: image)
                .aspectRatio(image.size, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .scaleEffect(zoomScale)
            .gesture(
                MagnificationGesture()
                    .onChanged { zoomScale = $0 }
                    .onEnded { _ in
                        if zoomScale < 1 { withAnimation { zoomScale = 1 } }
                    }
            )
        } else if viewModel.isLoadingImage {
            ProgressView().frame(maxWidth: .infinity, minHeight: 300)
        } else {
            Text("원본을 준비하지 못했어요.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 300)
        }
    }

    private var statusSection: some View {
        Text(statusText).font(.subheadline).foregroundStyle(.secondary)
    }

    // DETAIL-02. 미분석·실패·분류 보류를 구분한다 — 검색용 내부 정보(searchText·embedding 등)는
    // 여기서 표시·편집하지 않는다.
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

    @ViewBuilder
    private var foldersSection: some View {
        if viewModel.folders.isEmpty {
            Text("미분류").font(.footnote).foregroundStyle(.secondary)
        } else {
            Text(viewModel.folders.map(\.displayName).joined(separator: ", "))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var retrySection: some View {
        Button {
            Task { await viewModel.retry() }
        } label: {
            if viewModel.isRetrying {
                ProgressView()
            } else {
                Text("다시 분석하기")
            }
        }
        .buttonStyle(.bordered)
        .disabled(viewModel.isRetrying)
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
