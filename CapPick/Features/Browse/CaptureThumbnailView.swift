import SwiftUI

// 한 칸. 지금은 정사각형 균일 그리드다 — 화면설계서 BROWSE-01은 "이미지 비율에 따라 높이를
// 달리하는" 배치를 요구하지만(§7.3), 그 masonry 레이아웃은 다음 단계로 미루고 우선 실제
// 썸네일이 뜨는 것부터 만들었다. 가로세로 비율 자체는 Capture.width/height에 이미 있다.
struct CaptureThumbnailView: View {
    let capture: Capture
    let thumbnailLoader: any ThumbnailLoading
    /// 사용자가 방금 재시도 버튼을 눌러 지금 이 화면에서 진행 중인 요청. capture.searchState ==
    /// .processing(큐가 백그라운드에서 처리 중)과는 별개 — 둘 다 스피너로 보여준다.
    let isAnalyzing: Bool
    let onRetryTapped: () -> Void
    /// MEMBER-01의 "한 장" 케이스(FOLDER-03) — 폴더 목록과 두 콜백만 받는다. 현재 소속 여부는
    /// 미리 안 보여준다(addToFolder가 이미 소속돼도 안전해서 체크마크가 없어도 무해하다).
    let folders: [Folder]
    let onAddToFolder: (Folder) -> Void
    /// nil이면 "이 폴더에서 제거" 메뉴 자체를 안 보여준다(폴더 범위로 보고 있을 때만 의미가 있다).
    let onRemoveFromCurrentFolder: (() -> Void)?

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
            .contextMenu {
                if !folders.isEmpty {
                    Menu("폴더에 추가") {
                        ForEach(folders) { folder in
                            Button(folder.displayName) { onAddToFolder(folder) }
                        }
                    }
                }
                if let onRemoveFromCurrentFolder {
                    Button("이 폴더에서 제거", role: .destructive, action: onRemoveFromCurrentFolder)
                }
            }
            .task {
                image = await thumbnailLoader.thumbnail(
                    for: capture.photoAssetID, targetSize: CGSize(width: 300, height: 300))
            }
    }

    // 상태별 배지 — 임시 UI (DETAIL-01이 생기면 재시도는 거기로 옮긴다). pending은 큐가 알아서
    // 처리하므로 배지를 아예 안 띄운다(사용자 액션을 유도하지 않음). 밝은 스크린샷 위에서도
    // 보이도록 아이콘 뒤에 어두운 원형 배경을 깐다 — 배경 없이 흰 아이콘만 쓰면 밝은 이미지에
    // 묻혀 버튼이 있는지조차 안 보이는 문제가 있었다.
    @ViewBuilder
    private var analysisBadge: some View {
        if isAnalyzing || capture.searchState == .processing {
            badge { ProgressView().tint(.white) }
        } else if capture.searchState == .ready {
            badge {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
            }
        } else if capture.searchState == .failed {
            badge {
                Button(action: onRetryTapped) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.white)
                }
            }
        }
    }

    @ViewBuilder
    private func badge(@ViewBuilder content: () -> some View) -> some View {
        content()
            .font(.system(size: 14, weight: .semibold))
            .frame(width: 26, height: 26)
            .background(Circle().fill(.black.opacity(0.45)))
    }
}
