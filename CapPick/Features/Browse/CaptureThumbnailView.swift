import SwiftUI

// 한 칸. 지금은 정사각형 균일 그리드다 — 화면설계서 BROWSE-01은 "이미지 비율에 따라 높이를
// 달리하는" 배치를 요구하지만(§7.3), 그 masonry 레이아웃은 다음 단계로 미루고 우선 실제
// 썸네일이 뜨는 것부터 만들었다. 가로세로 비율 자체는 Capture.width/height에 이미 있다.
struct CaptureThumbnailView: View {
    let capture: Capture
    let thumbnailLoader: any ThumbnailLoading
    let isAnalyzing: Bool
    let onAnalyzeTapped: () -> Void

    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.15))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .overlay(alignment: .topTrailing) {
                analysisBadge.padding(6)
            }
            .clipped()
            .task {
                image = await thumbnailLoader.thumbnail(
                    for: capture.photoAssetID, targetSize: CGSize(width: 300, height: 300))
            }
    }

    // 임시 UI — DETAIL-01(캡처 상세)이 생기면 "분석" 버튼은 거기로 옮기고 여긴 상태 배지만 남긴다.
    // 밝은 스크린샷 위에서도 보이도록 아이콘 뒤에 어두운 원형 배경을 깐다 — 배경 없이 흰 아이콘만
    // 쓰면 밝은 이미지에 묻혀 버튼이 있는지조차 안 보이는 문제가 있었다.
    @ViewBuilder
    private var analysisBadge: some View {
        Group {
            if isAnalyzing {
                ProgressView().tint(.white)
            } else if capture.searchState == .ready {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
            } else {
                Button(action: onAnalyzeTapped) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.white)
                }
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .frame(width: 26, height: 26)
        .background(Circle().fill(.black.opacity(0.45)))
    }
}
