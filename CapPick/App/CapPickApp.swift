import SwiftUI

@main
struct CapPickApp: App {
    private let startup: Result<AppEnvironment, Error>

    init() {
        startup = Result { try AppEnvironment.live() }
    }

    var body: some Scene {
        WindowGroup {
            switch startup {
            case .success(let environment):
                RootView(environment: environment)
            case .failure:
                Text("저장소를 열지 못했어요. 앱을 다시 실행해 주세요.")
                    .padding()
            }
        }
    }
}
