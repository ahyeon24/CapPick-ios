import SwiftUI

/// HOME-01 폴더 카드 하나 — 위쪽은 대표 캡처 한 장(그 폴더의 가장 최근 캡처), 아래쪽은 이름·장수.
/// 2026-10-15 모노톤 홈 디자인(사용자가 준 Figma 시안)에 맞춘 모양이다. 사용자 폴더만 ··· 관리
/// 메뉴(menu)를 받고, 전체·미분류는 nil이라 메뉴가 없다.
struct FolderCardView<Destination: View, Menu: View>: View {
    let title: String
    let count: Int
    let photoAssetID: String?
    let thumbnailLoader: any ThumbnailLoading
    /// 기존 캡처 분류 진행 상황 같은 한 줄 안내(예: "분류 중 12/86"). nil이면 장수만 보인다.
    var status: String? = nil
    @ViewBuilder let destination: () -> Destination
    /// nil이면 ··· 버튼을 안 보여준다.
    let menu: (() -> Menu)?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            NavigationLink(destination: destination) {
                FolderCardPreview(photoAssetID: photoAssetID, thumbnailLoader: thumbnailLoader)
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
                        Text(status.map { "\(count.formatted())장 · \($0)" } ?? "\(count.formatted())장")
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
        title: String, count: Int, photoAssetID: String?, thumbnailLoader: any ThumbnailLoading,
        @ViewBuilder destination: @escaping () -> Destination
    ) {
        self.init(
            title: title, count: count, photoAssetID: photoAssetID, thumbnailLoader: thumbnailLoader,
            destination: destination, menu: nil)
    }
}

/// 대표 캡처 한 장을 카드 가득 채운다(위쪽 기준으로 잘림 — 스크린샷은 위쪽에 앱 이름·제목이
/// 있는 경우가 많아서). 2026-10-17 사용자 결정으로 여러 장 겹친 콜라주에서 한 장으로 바꿨다.
/// 캡처가 없으면 빈 회색 카드.
private struct FolderCardPreview: View {
    let photoAssetID: String?
    let thumbnailLoader: any ThumbnailLoading
    @State private var image: UIImage?

    var body: some View {
        RoundedRectangle(cornerRadius: AppPalette.radius, style: .continuous)
            .fill(AppPalette.surface)
            .frame(height: 132)
            .overlay(alignment: .top) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AppPalette.radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppPalette.radius, style: .continuous)
                    .strokeBorder(AppPalette.separator, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: AppPalette.radius, style: .continuous))
            .task(id: photoAssetID) {
                image = nil
                guard let photoAssetID else { return }
                image = await thumbnailLoader.thumbnail(for: photoAssetID, targetSize: CGSize(width: 520, height: 1040))
            }
    }
}
