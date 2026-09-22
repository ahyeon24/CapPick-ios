import SwiftUI

// 한 칸. 지금은 정사각형 균일 그리드다 — 화면설계서 BROWSE-01은 "이미지 비율에 따라 높이를
// 달리하는" 배치를 요구하지만(§7.3), 그 masonry 레이아웃은 다음 단계로 미루고 우선 실제
// 썸네일이 뜨는 것부터 만들었다. 가로세로 비율 자체는 Capture.width/height에 이미 있다.
struct CaptureThumbnailView: View {
    let capture: Capture
    let thumbnailLoader: any ThumbnailLoading

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
            .clipped()
            .task {
                image = await thumbnailLoader.thumbnail(
                    for: capture.photoAssetID, targetSize: CGSize(width: 300, height: 300))
            }
    }
}
