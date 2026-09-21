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
            ProgressView().task { await decideRoute() }
        case .onboarding:
            OnboardingFlowView(viewModel: OnboardingViewModel(
                library: environment.library,
                syncService: environment.syncService,
                captureStore: environment.captureStore,
                appStateStore: environment.appStateStore,
                onFinished: { route = .home }
            ))
        case .home:
            HomeView(viewModel: HomeViewModel(
                library: environment.library,
                syncService: environment.syncService,
                captureStore: environment.captureStore
            ))
        }
    }

    private func decideRoute() async {
        let completed = try? await environment.appStateStore.value(for: AppStateKey.onboardingCompleted)
        route = completed == "true" ? .home : .onboarding
    }
}
