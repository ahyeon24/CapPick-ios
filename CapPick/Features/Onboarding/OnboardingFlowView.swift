import SwiftUI
import UIKit

struct OnboardingFlowView: View {
    @State private var viewModel: OnboardingViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    init(viewModel: OnboardingViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Group {
            switch viewModel.step {
            case .welcome: welcome
            case .photoAccess: photoAccess
            case .analysisStart: analysisStart
            }
        }
        .padding(24)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await viewModel.refreshAfterReturning() }
            }
        }
    }

    // ON-01 시작 안내
    private var welcome: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("CapPick").font(.largeTitle.bold())
            Text("쌓아둔 캡처, 기억나는 말로 찾아보세요").font(.title3)
            Text("기존 스크린샷을 찾아 폴더로 정리하고, 필요한 캡처를 검색으로 다시 찾을 수 있어요.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button("시작하기") { Task { await viewModel.start() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    // ON-02 사진 접근
    private var photoAccess: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("기존 스크린샷을 찾아 정리하려면 사진 접근이 필요해요.")
                .font(.title3)
                .multilineTextAlignment(.center)
            authorizationNote
            if viewModel.isWorking {
                ProgressView("스크린샷을 확인하고 있어요.")
            }
            if let message = viewModel.errorMessage {
                Text(message).foregroundStyle(.red).font(.footnote)
            }
            Spacer()
            photoAccessButton
            Button("지금은 건너뛰기") { Task { await viewModel.skipPhotoAccess() } }
        }
    }

    @ViewBuilder
    private var authorizationNote: some View {
        switch viewModel.authorization {
        case .denied:
            Text("사진 접근이 꺼져 있어요. 설정에서 허용하면 기존 스크린샷을 정리할 수 있어요.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        case .restricted:
            Text("이 기기에서는 사진 접근이 제한되어 있어요.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        case .limited:
            Text("허용한 사진 중 스크린샷만 정리해요.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        case .notDetermined, .authorized:
            EmptyView()
        }
    }

    @ViewBuilder
    private var photoAccessButton: some View {
        switch viewModel.authorization {
        case .denied, .restricted:
            Button("설정으로 이동") { openSettings() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        case .notDetermined, .limited, .authorized:
            Button("사진 접근 허용") { Task { await viewModel.requestPhotoAccess() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(viewModel.isWorking)
        }
    }

    // ON-03 전체 분석 시작
    private var analysisStart: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("기존 캡처를 정리할게요").font(.title2.bold())
            if viewModel.screenshotCount == 0 {
                Text("접근 가능한 스크린샷이 없어요.")
                Text("사진 접근 권한을 확인하거나 허용할 사진을 추가해 주세요.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("접근 가능한 스크린샷 \(viewModel.screenshotCount.formatted())장")
                Text("최근 캡처부터 차례로 분석해요.").font(.subheadline).foregroundStyle(.secondary)
            }
            // 분석 기능을 연결하기 전이라 실제로 외부로 전송되는 정보가 없다. 최종 안내 문구는 AI 공급자 선정 후 확정.
            Text("AI 처리 안내(임시): 분석 기능을 연결하기 전이라 아직 외부로 전송되는 정보는 없어요.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let message = viewModel.errorMessage {
                Text(message).foregroundStyle(.red).font(.footnote)
            }
            Spacer()
            Button("전체 캡처 분석 시작") { Task { await viewModel.startAnalysis() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(viewModel.screenshotCount == 0 || viewModel.isWorking)
            Button("나중에 시작하기") { Task { await viewModel.postponeAnalysis() } }
                .disabled(viewModel.isWorking)
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }
}
