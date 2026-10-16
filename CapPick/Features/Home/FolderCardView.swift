import SwiftUI

/// HOME-01 폴더 카드 하나 — 위쪽은 최근 캡처를 살짝 기울여 겹친 미리보기, 아래쪽은 이름·장수.
/// 2026-10-15 모노톤 홈 디자인(사용자가 준 Figma 시안)에 맞춘 모양이다. 사용자 폴더만 ··· 관리
/// 메뉴(menu)를 받고, 전체·미분류는 nil이라 메뉴가 없다.
struct FolderCardView<Destination: View, Menu: View>: View {
    let title: String
    let count: Int
    let photoAssetIDs: [String]
    let thumbnailLoader: any ThumbnailLoading
    @ViewBuilder let destination: () -> Destination
    /// nil이면 ··· 버튼을 안 보여준다.
    let menu: (() -> Menu)?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            NavigationLink(destination: destination) {
                FolderCardPreview(photoAssetIDs: photoAssetIDs, thumbnailLoader: thumbnailLoader)
            }
            .buttonStyle(.plain)

            HStack(alignment: .top) {
                NavigationLink(destination: destination) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 15, weight: .bold))
                            .tracking(-0.25)
                            .foregroundStyle(AppPalette.text)
                            .lineLimit(1)
                        Text("\(count.formatted())장")
                            .font(.system(size: 12))
                            .tracking(-0.15)
                            .foregroundStyle(AppPalette.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                if let menu {
                    SwiftUI.Menu {
                        menu()
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(AppPalette.text)
                            .frame(width: 32, height: 22)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("\(title) 폴더 관리")
                }
            }
        }
    }
}

extension FolderCardView where Menu == EmptyView {
    /// 전체·미분류처럼 관리 메뉴가 없는 카드.
    init(
        title: String, count: Int, photoAssetIDs: [String], thumbnailLoader: any ThumbnailLoading,
        @ViewBuilder destination: @escaping () -> Destination
    ) {
        self.init(
            title: title, count: count, photoAssetIDs: photoAssetIDs, thumbnailLoader: thumbnailLoader,
            destination: destination, menu: nil)
    }
}

/// 최근 캡처 최대 3장을 겹쳐 놓은 미리보기. 위치·크기·기울기는 시안의 전체 카드 콜라주
/// (.food-mini / .shop-mini / .article-mini)를 그대로 따랐다 — 카드 가장자리에서 일부가 잘려 보이는
/// 것도 시안 그대로다. 맨 앞(오른쪽 아래)이 가장 최근 캡처다. 캡처가 없으면 빈 회색 카드.
private struct FolderCardPreview: View {
    let photoAssetIDs: [String]
    let thumbnailLoader: any ThumbnailLoading

    private struct Slot {
        let size: CGSize
        /// 카드 왼쪽 위 기준 미리보기 중심 위치(시안 좌표, 카드 폭 170 기준).
        let center: CGPoint
        let angle: Double
    }

    // 뒤 → 앞. 카드 높이 132, 폭은 화면에 따라 달라서 x는 폭 비율로 바꿔 쓴다.
    private static let slots: [Slot] = [
        Slot(size: CGSize(width: 70, height: 106), center: CGPoint(x: 42, y: 61), angle: -2),
        Slot(size: CGSize(width: 67, height: 105), center: CGPoint(x: 95.5, y: 43.5), angle: 2),
        Slot(size: CGSize(width: 75, height: 94), center: CGPoint(x: 128.5, y: 110), angle: -1),
    ]
    private static let designWidth: CGFloat = 170

    var body: some View {
        let ids = Array(photoAssetIDs.prefix(3).reversed())
        RoundedRectangle(cornerRadius: AppPalette.radius, style: .continuous)
            .fill(ids.isEmpty ? AppPalette.surface : AppPalette.collage)
            .frame(height: 132)
            .overlay {
                GeometryReader { proxy in
                    let scale = proxy.size.width / Self.designWidth
                    ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                        // 장수가 적으면 앞쪽 슬롯부터 채워서, 1장이어도 맨 앞(가장 잘 보이는) 자리에 온다.
                        let slot = Self.slots[(Self.slots.count - ids.count) + index]
                        PreviewThumbnail(photoAssetID: id, thumbnailLoader: thumbnailLoader, size: slot.size)
                            .rotationEffect(.degrees(slot.angle))
                            .position(x: slot.center.x * scale, y: slot.center.y)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AppPalette.radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppPalette.radius, style: .continuous)
                    .strokeBorder(AppPalette.separator, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: AppPalette.radius, style: .continuous))
    }
}

private struct PreviewThumbnail: View {
    let photoAssetID: String
    let thumbnailLoader: any ThumbnailLoading
    let size: CGSize
    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(.white)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .overlay { Rectangle().strokeBorder(AppPalette.miniBorder, lineWidth: 1) }
            .shadow(color: .black.opacity(0.08), radius: 3, y: 2)
            .task(id: photoAssetID) {
                image = await thumbnailLoader.thumbnail(
                    for: photoAssetID, targetSize: CGSize(width: size.width * 3, height: size.height * 3))
            }
    }
}
