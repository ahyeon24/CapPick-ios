import SwiftUI

/// 앱 전체 모노톤 디자인 값. 2026-10-15 홈 시안(Figma Make "iOS-Home-Screen-Design", src/index.css의
/// :root 토큰)에서 그대로 옮겼고, 2026-10-16부터 다른 화면도 이 값을 같이 쓴다(사용자 결정).
enum AppPalette {
    static let text = Color(red: 0x11 / 255, green: 0x11 / 255, blue: 0x11 / 255)        // #111111
    static let secondary = Color(red: 0x77 / 255, green: 0x77 / 255, blue: 0x77 / 255)   // #777777
    static let surface = Color(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF5 / 255)     // #F5F5F5
    static let separator = Color(red: 0xE8 / 255, green: 0xE8 / 255, blue: 0xE8 / 255)   // #E8E8E8
    static let collage = Color(red: 0xD8 / 255, green: 0xD8 / 255, blue: 0xD8 / 255)     // #D8D8D8
    static let miniBorder = Color(red: 0xDE / 255, green: 0xDE / 255, blue: 0xDE / 255)  // #DEDEDE
    /// 시안의 --radius-medium.
    static let radius: CGFloat = 8
    /// 시안의 화면 좌우 여백(--space-5).
    static let horizontalPadding: CGFloat = 20

    /// 화면 큰 제목(시안 .detail-title 32 / .search-heading 26 등). 한글은 굵기가 정해진 글꼴로
    /// 그려져서 시안의 730~750을 한 단계 위(heavy)로 둔다 — 홈에서 시안과 나란히 비교해 정했다.
    static func title(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy) }
}

/// 시안의 검정 꽉 찬 버튼(온보딩·시트의 주요 동작).
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: AppPalette.radius, style: .continuous)
                    .fill(isEnabled ? AppPalette.text : AppPalette.separator))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// 시안의 회색 검색·입력 상자(#F5F5F5 면 + #E8E8E8 테두리 + 모서리 8).
struct FieldBoxModifier: ViewModifier {
    var height: CGFloat = 46

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 13)
            .frame(minHeight: height)
            .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: AppPalette.radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppPalette.radius, style: .continuous)
                    .strokeBorder(AppPalette.separator, lineWidth: 1)
            }
    }
}

extension View {
    func fieldBox(height: CGFloat = 46) -> some View { modifier(FieldBoxModifier(height: height)) }
}
