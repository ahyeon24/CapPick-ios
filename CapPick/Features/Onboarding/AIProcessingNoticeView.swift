import SwiftUI

/// ON-03의 "AI 처리 안내". 2026-10-15 기준 실제 동작(기기 OCR·기기 검색, 분석만 서버→Gemini)에 맞춘
/// 초안이다. 공급자 이용 약관(데이터 활용 범위)과 보존 기간은 아직 확정되지 않아서, 확정되지 않은
/// 약속("학습에 쓰이지 않아요" 등)은 일부러 넣지 않았다 — 지금 쓰는 Gemini 무료 티어는 보낸 데이터가
/// 서비스 개선에 쓰일 수 있다. 출시 전에 공급자·요금제와 함께 다시 확정해야 한다.
struct AIProcessingNoticeView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("분석을 위해 보내는 것") {
                    noticeRow("photo", "분석할 스크린샷의 축소 이미지")
                    noticeRow("text.viewfinder", "휴대폰에서 읽어낸 스크린샷 속 글자")
                }
                Section("어디에서 처리하나요") {
                    noticeRow("server.rack", "CapPick 서버를 거쳐 Google의 AI(Gemini)가 화면 내용을 요약해요.")
                    noticeRow("iphone", "결과(요약·관찰 내용)는 이 휴대폰에만 저장돼요. 서버는 결과를 잠시 보관했다가 지워요.")
                }
                Section("휴대폰 안에서만 처리하는 것") {
                    noticeRow("magnifyingglass", "검색어와 검색은 휴대폰 밖으로 보내지 않아요.")
                    noticeRow("folder", "폴더와 폴더 정리 기록은 휴대폰에만 저장돼요.")
                    noticeRow("photo.on.rectangle", "사진 앱의 원본은 이동하거나 삭제하지 않아요.")
                }
                Section {
                    Text("설정 > 앱 데이터 삭제에서 휴대폰과 서버에 남은 CapPick 데이터를 지울 수 있어요.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("AI 처리 안내")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("확인") { dismiss() }
                }
            }
        }
    }

    private func noticeRow(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint)
        }
    }
}
