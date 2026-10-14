import XCTest
@testable import CapPick

final class MasonryLayoutTests: XCTestCase {
    func testEachCaptureGoesToTheCurrentlyShorterColumnKeepingOrder() {
        // 0번(긴 캡처, 2.0)이 왼쪽을 길게 만들면, 오른쪽이 2.0을 넘기 전까지(1.0 → 1.8 → 2.8)
        // 다음 캡처들이 전부 오른쪽으로 간다. 그다음(4번)은 다시 짧아진 왼쪽으로.
        let layout = MasonryLayout.columns(heightRatios: [2.0, 1.0, 0.8, 1.0, 1.0])

        XCTAssertEqual(layout.left, [0, 4])
        XCTAssertEqual(layout.right, [1, 2, 3])
    }

    func testFirstTwoCapturesAreAlwaysAtTheTopOfEachColumn() {
        let layout = MasonryLayout.columns(heightRatios: [1.5, 1.5, 1.5])

        XCTAssertEqual(layout.left.first, 0)
        XCTAssertEqual(layout.right.first, 1)
    }

    func testHeightRatioIsClampedAndFallsBackToSquare() {
        // 아이폰 세로 스크린샷(약 2.17)은 카드 비율 상한에 맞춰 잘린다.
        XCTAssertEqual(MasonryLayout.heightRatio(width: 1179, height: 2556), MasonryLayout.maxHeightRatio)
        XCTAssertEqual(MasonryLayout.heightRatio(width: 2940, height: 422), MasonryLayout.minHeightRatio)
        XCTAssertEqual(MasonryLayout.heightRatio(width: 1000, height: 1200), 1.2)
        XCTAssertEqual(MasonryLayout.heightRatio(width: 0, height: 0), 1)
    }
}
