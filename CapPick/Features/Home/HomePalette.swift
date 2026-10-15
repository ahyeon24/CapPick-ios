import SwiftUI

/// 2026-10-15 모노톤 홈 시안(Figma Make "iOS-Home-Screen-Design", src/index.css의 :root 토큰)에서
/// 그대로 옮긴 값. 시안 밖의 다른 화면은 시스템 기본색 + 검정 강조색(AccentColor)을 쓴다.
enum HomePalette {
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
}
