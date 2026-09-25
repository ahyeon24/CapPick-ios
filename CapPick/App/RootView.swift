import SwiftUI

struct RootView: View {
    let environment: AppEnvironment

    private enum Route {
        case loading
        case onboarding
        case home
    }

    @State private var route: Route = .loading

    var body: some View {
        switch route {
        case .loading:
            ProgressView().task {
                // 설치 등록은 화면 흐름과 무관하게 백그라운드로 진행한다 — 실패해도(서버 미기동 등)
                // 온보딩/홈 진입을 막지 않는다. 로그인 화면이 아니므로 사용자에게 결과를 묻지 않는다.
                Task { try? await environment.installationRegistrar.ensureRegistered() }
                await decideRoute()
            }
        case .onboarding:
            OnboardingFlowView(viewModel: OnboardingViewModel(
                library: environment.library,
                syncService: environment.syncService,
                captureStore: environment.captureStore,
                appStateStore: environment.appStateStore,
                onFinished: { route = .home }
            ))
        case .home:
            HomeView(
                viewModel: HomeViewModel(
                    library: environment.library,
                    syncService: environment.syncService,
                    captureStore: environment.captureStore,
                    folderStore: environment.folderStore,
                    appStateStore: environment.appStateStore,
                    analysisQueueService: environment.analysisQueueService
                ),
                captureStore: environment.captureStore,
                folderStore: environment.folderStore,
                thumbnailLoader: environment.thumbnailLoader,
                analysisQueueService: environment.analysisQueueService,
                searchService: environment.searchService,
                reclassificationStore: environment.reclassificationStore,
                reclassificationService: environment.reclassificationService
            )
        }
    }

    private func decideRoute() async {
        let completed = try? await environment.appStateStore.value(for: AppStateKey.onboardingCompleted)
        route = completed == "true" ? .home : .onboarding
    }
}
