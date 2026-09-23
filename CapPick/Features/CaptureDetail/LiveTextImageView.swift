import SwiftUI
import VisionKit

/// Live Text(VisionKit) — 이미지 위에서 시스템 사진 앱과 똑같은 방식으로 글자를 길게 눌러
/// 선택·복사할 수 있게 한다(DETAIL-03). 서버 OCR(content_analysis 결과)과는 완전히 별개로
/// 기기에서 즉시 동작한다 — 분석 대기·실패 상태의 캡처에서도 쓸 수 있다. 서버 OCR은 검색에만
/// 쓰이고(SearchRanking), 상세 화면의 "글자 복사"는 이제 이 경로만 쓴다.
struct LiveTextImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.isUserInteractionEnabled = true
        let interaction = ImageAnalysisInteraction()
        imageView.addInteraction(interaction)
        context.coordinator.interaction = interaction
        context.coordinator.analyze(image)
        return imageView
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        guard uiView.image !== image else { return }
        uiView.image = image
        context.coordinator.analyze(image)
    }

    // UIImageView의 고유 크기(원본 이미지 픽셀 크기)를 그대로 쓰려는 기본 동작을 무시하고,
    // SwiftUI가 제안한 크기를 그대로 쓴다 — .aspectRatio 같은 바깥 수정자가 계산한 크기가
    // 항상 이긴다. 이게 없으면 큰 스크린샷이 화면 너비를 무시하고 원본 크기로 그려진다.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIImageView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private let analyzer = ImageAnalyzer()
        var interaction: ImageAnalysisInteraction?

        func analyze(_ image: UIImage) {
            let interaction = interaction
            Task {
                let configuration = ImageAnalyzer.Configuration([.text])
                guard let analysis = try? await analyzer.analyze(image, configuration: configuration) else { return }
                interaction?.analysis = analysis
                interaction?.preferredInteractionTypes = .textSelection
            }
        }
    }
}
