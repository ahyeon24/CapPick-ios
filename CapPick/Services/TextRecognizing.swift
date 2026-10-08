import Foundation

// 서버로 올리는 content_analysis 요청에 붙일 OCR 텍스트를 기기에서 만든다(API 명세 §4 "선택
// ocr_text"). CaptureImageProviding과 별개인 이유: 업로드용 이미지는 줄이고 압축한 JPEG이지만,
// 글자 인식은 작은 글씨를 놓치지 않게 원본 해상도로 해야 한다.
protocol TextRecognizing: Sendable {
    /// 인식한 글자를 줄 단위로 이어 붙인 텍스트. 원본을 못 읽었거나 글자가 하나도 없으면 nil —
    /// 이 경우 서버가 예전처럼 AI 모델에게 OCR까지 맡긴다.
    func recognizeText(for photoAssetID: String) async -> String?
}
