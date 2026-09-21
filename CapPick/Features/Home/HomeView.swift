import SwiftUI
import UIKit

struct HomeView: View {
    @State private var viewModel: HomeViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    init(viewModel: HomeViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CapPick").font(.largeTitle.bold())
            content
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await viewModel.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await viewModel.refresh() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !viewModel.authorization.canReadPhotos {
            Text("사진 접근이 필요해요.").font(.title3)
            Text("설정에서 사진 접근을 허용하면 기존 스크린샷을 찾아 정리할 수 있어요.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("설정으로 이동") { openSettings() }
                .buttonStyle(.borderedProminent)
        } else if let progress = viewModel.progress {
            if viewModel.authorization == .limited {
                Text("허용한 사진 중 스크린샷만 보여요. 기존 캡처 전체가 아닐 수 있어요.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text("접근 가능한 스크린샷 \(progress.total.formatted())장").font(.title3)
            Text("\(progress.searchReady.formatted()) / \(progress.total.formatted())장 분석 완료")
                .foregroundStyle(.secondary)
        } else if let message = viewModel.errorMessage {
            Text(message).foregroundStyle(.red)
        } else {
            ProgressView()
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }
}
