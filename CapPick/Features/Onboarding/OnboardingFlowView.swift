import SwiftUI
import UIKit

struct OnboardingFlowView: View {
    @State private var viewModel: OnboardingViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var isShowingAINotice = false

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

    // ON-01 시작 안내 — 기능 설명 캐러셀 없이 핵심 한 가지만 전달한다(2026-10-15 사용자 결정).
    private var welcome: some View {
        VStack(spacing: 16) {
            Spacer()
            // 앱 아이콘이 정해지면 이 자리를 아이콘 이미지로 바꾼다(아직 아이콘 없음).
            symbolBadge("photo.stack")
            Text("CapPick")
                .font(.system(size: 34, weight: .heavy))
                .tracking(-1.5)
            Text("쌓아둔 캡처,\n기억나는 말로 찾아보세요")
                .font(.title3)
                .multilineTextAlignment(.center)
            Text("AI가 스크린샷의 내용을 분석해서\n필요한 캡처를 쉽게 찾고 정리해줘요.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button("시작하기") { Task { await viewModel.start() } }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    // ON-02 사진 접근
    private var photoAccess: some View {
        VStack(spacing: 16) {
            Spacer()
            symbolBadge("photo.on.rectangle")
            Text("스크린샷을 불러올게요").font(AppPalette.title(26)).tracking(-1)
            Text("CapPick이 기존 스크린샷을 찾고\n정리하려면 사진 접근이 필요해요.")
                .multilineTextAlignment(.center)
            Text("사진 앱의 원본을 이동하거나 삭제하지 않아요.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
            Button("나중에 하기") { Task { await viewModel.skipPhotoAccess() } }
                .foregroundStyle(AppPalette.secondary)
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
                .buttonStyle(PrimaryButtonStyle())
        case .notDetermined, .limited, .authorized:
            Button("사진 접근 허용") { Task { await viewModel.requestPhotoAccess() } }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(viewModel.isWorking)
        }
    }

    // ON-03 전체 분석 시작 — 사진 권한과 별개로, 외부 AI 처리를 여기서 처음 안내하고 동의받는다.
    private var analysisStart: some View {
        VStack(spacing: 14) {
            Spacer()
            symbolBadge("sparkles")
            if viewModel.screenshotCount == 0 {
                Text("접근 가능한 스크린샷이 없어요").font(AppPalette.title(26)).tracking(-1)
                Text("사진 접근 권한을 확인하거나 허용할 사진을 추가해 주세요.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                Text("\(viewModel.screenshotCount.formatted())개의 캡처를 찾았어요")
                    .font(AppPalette.title(26))
                    .tracking(-1)
                    .multilineTextAlignment(.center)
                Text("최근 캡처부터 차례대로 분석해\n검색할 수 있게 준비할게요.")
                    .multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 8) {
                    checkRow("완료된 캡처부터 바로 검색 가능")
                    checkRow("앱을 다시 열면 남은 분석 이어서 진행")
                }
                .font(.subheadline)
                .padding(.top, 4)
            }
            Button {
                isShowingAINotice = true
            } label: {
                Label("AI 처리 안내", systemImage: "chevron.right")
                    .labelStyle(TrailingIconLabelStyle())
                    .font(.subheadline)
            }
            .padding(.top, 4)
            if let message = viewModel.errorMessage {
                Text(message).foregroundStyle(.red).font(.footnote)
            }
            Spacer()
            Button("캡처 분석 시작하기") { Task { await viewModel.startAnalysis() } }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(viewModel.screenshotCount == 0 || viewModel.isWorking)
            Button("나중에 하기") { Task { await viewModel.postponeAnalysis() } }
                .foregroundStyle(AppPalette.secondary)
                .disabled(viewModel.isWorking)
        }
        .sheet(isPresented: $isShowingAINotice) {
            AIProcessingNoticeView()
        }
    }

    private func symbolBadge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 34, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 76, height: 76)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(AppPalette.text))
            .padding(.bottom, 4)
    }

    private func checkRow(_ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "checkmark").foregroundStyle(AppPalette.text)
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }
}

/// "AI 처리 안내 ›"처럼 아이콘을 글자 뒤에 붙인다.
private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.font(.caption.weight(.semibold))
        }
    }
}
