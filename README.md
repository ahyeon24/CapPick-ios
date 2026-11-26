# CapPick-ios

**캡픽: 쌓아 둔 스크린샷을 AI가 정리하고, 말로 검색해 다시 찾는 아이폰 앱.** (SwiftUI)

- 사진 보관함의 스크린샷을 찾아 자동으로 순서대로 분석하고, 앱이 꺼져도 이어서 처리한다.
- 검색은 서버 없이 기기에서 한다. 다국어 임베딩 모델(multilingual-e5-small, ONNX)과 키워드 검색을 RRF로 합친다.
- 글자 인식(OCR)은 기기(Apple Vision)에서 해서 서버로 보낸다. 이렇게 바꿔 장당 분석 비용을 약 1.4원에서 약 0.85원으로 줄였다.
- 폴더 자동 분류와 재분류, 사진 앱처럼 글자를 길게 눌러 복사하는 상세 화면(Live Text).
- 로그인 없이 앱 설치 단위(App Attest)로 서버 요청을 보호한다.

**기술**: SwiftUI · GRDB(SQLite) · ONNX Runtime · swift-transformers · VisionKit · XcodeGen

관련 저장소: [CapPick-server](https://github.com/ahyeon24/CapPick-server) · [CapPick-docs](https://github.com/ahyeon24/CapPick-docs)(기획·화면·API 명세)
