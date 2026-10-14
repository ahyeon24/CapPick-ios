import Foundation

/// 화면설계서 BROWSE-01 §7.3 "이미지 비율에 따라 높이가 다른 2열 목록"의 배치 계산. 순수 함수.
///
/// 캡처를 순서대로 보면서 지금까지 더 짧은 열에 붙인다 — 그래서 앞쪽(관련도가 높거나 최근인)
/// 캡처는 항상 화면 위쪽에 놓이고, 두 열의 길이는 비슷하게 유지된다.
enum MasonryLayout {
    /// 세로/가로 비율의 허용 범위 — 범위를 벗어난 부분은 가운데 기준으로 잘려서 보인다.
    /// 2026-10-14 사용자 요청으로 핀터레스트처럼 카드가 살짝 세로로 긴 정도(최대 약 1:1.45)가
    /// 되게 좁혔다. 처음엔 2.2까지 허용해서 아이폰 세로 스크린샷(약 1:2.17)이 잘리지 않고 통째로
    /// 보였는데, 그러면 한 칸이 화면 절반을 차지해 한 번에 보이는 캡처가 너무 적었다. 잠정치.
    static let minHeightRatio = 0.75
    static let maxHeightRatio = 1.45

    /// 칸에 쓸 세로/가로 비율. 크기 정보가 없으면 정사각형.
    static func heightRatio(width: Int, height: Int) -> Double {
        guard width > 0, height > 0 else { return 1 }
        return min(max(Double(height) / Double(width), minHeightRatio), maxHeightRatio)
    }

    /// 각 칸의 세로/가로 비율을 받아 (왼쪽 열, 오른쪽 열)에 들어갈 원래 인덱스를 돌려준다.
    static func columns(heightRatios: [Double]) -> (left: [Int], right: [Int]) {
        var left: [Int] = [], right: [Int] = []
        var leftHeight = 0.0, rightHeight = 0.0
        for (index, ratio) in heightRatios.enumerated() {
            if leftHeight <= rightHeight {
                left.append(index)
                leftHeight += ratio
            } else {
                right.append(index)
                rightHeight += ratio
            }
        }
        return (left, right)
    }
}
