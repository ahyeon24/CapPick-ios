import SwiftUI
import UIKit

struct HomeView: View {
    @State private var viewModel: HomeViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    private let captureStore: any CaptureStoring
    private let folderStore: any FolderStoring
    private let thumbnailLoader: any ThumbnailLoading
    private let analysisQueueService: AnalysisQueueService
    private let searchService: SearchService
    private let reclassificationStore: any ReclassificationStoring
    private let reclassificationCoordinator: ReclassificationCoordinator
    private let usageService: UsageService
    private let appDataDeletionService: AppDataDeletionService

    @State private var isCreatingFolder = false
    @State private var isShowingSettings = false
    @State private var reclassificationTarget: ReclassificationTarget?
    @State private var editingFolder: Folder?
    @State private var folderPendingDeletion: Folder?
    // 화면설계서 §7.1·§7.2 HOME-01 상단 검색. 홈 검색창은 마지막 입력을 유지하는 초안이라
    // @State로 충분하다 — NavigationStack에서 자식을 pop해 돌아와도 이 뷰 자체는 다시 안 만들어져
    // 값이 그대로 남는다. 실행은 pendingSearch를 통해서만 한다(입력마다 검색하지 않음).
    @State private var searchQuery = ""
    @State private var pendingSearch: PendingSearch?

    private struct PendingSearch: Identifiable, Hashable {
        let id = UUID()
        let query: String
    }

    private let cardColumns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    init(
        viewModel: HomeViewModel, captureStore: any CaptureStoring, folderStore: any FolderStoring,
        thumbnailLoader: any ThumbnailLoading, analysisQueueService: AnalysisQueueService,
        searchService: SearchService, reclassificationStore: any ReclassificationStoring,
        reclassificationCoordinator: ReclassificationCoordinator, usageService: UsageService,
        appDataDeletionService: AppDataDeletionService
    ) {
        _viewModel = State(initialValue: viewModel)
        self.captureStore = captureStore
        self.folderStore = folderStore
        self.thumbnailLoader = thumbnailLoader
        self.analysisQueueService = analysisQueueService
        self.searchService = searchService
        self.reclassificationStore = reclassificationStore
        self.reclassificationCoordinator = reclassificationCoordinator
        self.usageService = usageService
        self.appDataDeletionService = appDataDeletionService
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    content
                }
                .padding(.horizontal, AppPalette.horizontalPadding)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(.systemBackground))
            // 2026-10-15 모노톤 시안: 내비게이션 바 없이 로고·설정 버튼을 화면 안에 직접 둔다.
            // 이 화면에서만 숨기므로 Browse 등 들어간 화면에는 바가 그대로 보인다.
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $isShowingSettings) {
                SettingsView(viewModel: SettingsViewModel(
                    usageService: usageService, appDataDeletionService: appDataDeletionService))
            }
            .onChange(of: isShowingSettings) { wasShowing, isShowing in
                // 앱 데이터 삭제가 여기서 일어날 수 있다 — 닫히면(특히 삭제 후) 폴더 카드
                // 개수를 새로 고친다.
                if wasShowing, !isShowing {
                    Task { await viewModel.refresh() }
                }
            }
            .task { await viewModel.refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await viewModel.refresh() }
                }
            }
            .onAppear {
                // BROWSE-01/DETAIL-01에서 캡픽 제외 등으로 돌아왔을 때 폴더 카드 개수를 새로
                // 고친다 — pop으로 돌아오는 건 이 뷰를 다시 만들지 않아 .task가 재실행 안 된다.
                Task { await viewModel.refresh() }
            }
            .sheet(isPresented: $isCreatingFolder) {
                FolderEditView(viewModel: FolderEditViewModel(
                    mode: .create, folderStore: folderStore,
                    onSaved: { folder, applyToExisting in
                        Task { await viewModel.refresh() }
                        // 창과 상관없이 끝까지 돌고, 끝나면 확인 없이 바로 폴더에 넣는다
                        // (ReclassificationCoordinator). 진행 상황은 폴더 카드에 보인다.
                        if applyToExisting {
                            reclassificationCoordinator.start(folder: folder, mode: .initialApply)
                        }
                    }))
            }
            .sheet(item: $editingFolder) { folder in
                // ··· 메뉴의 "이름 변경"·"분류 기준 수정" 둘 다 이 시트를 연다 — 지금 FOLDER-02 수정
                // 시트가 이름과 기준을 한 화면에서 같이 고치는 구조라서다.
                FolderEditView(viewModel: FolderEditViewModel(
                    mode: .edit(folder), folderStore: folderStore,
                    onSaved: { _, _ in Task { await viewModel.refresh() } }))
            }
            .alert(
                "폴더를 삭제할까요?",
                isPresented: Binding(get: { folderPendingDeletion != nil }, set: { if !$0 { folderPendingDeletion = nil } })
            ) {
                Button("삭제", role: .destructive) {
                    if let folder = folderPendingDeletion {
                        Task {
                            try? await folderStore.delete(id: folder.id)
                            await viewModel.refresh()
                        }
                    }
                }
                Button("취소", role: .cancel) {}
            } message: {
                Text("폴더만 삭제돼요. 원본 캡처와 다른 폴더 소속은 유지돼요.")
            }
            .sheet(item: $reclassificationTarget) { target in
                NavigationStack {
                    ReclassificationView(viewModel: ReclassificationViewModel(
                        folder: target.folder, mode: target.mode, coordinator: reclassificationCoordinator,
                        reclassificationStore: reclassificationStore, captureStore: captureStore,
                        thumbnailLoader: thumbnailLoader))
                }
                .onDisappear { Task { await viewModel.refresh() } }
            }
            .onChange(of: reclassificationCoordinator.completedCount) { _, _ in
                Task { await viewModel.refresh() }
            }
            .navigationDestination(item: $pendingSearch) { pending in
                BrowseView(
                    viewModel: BrowseViewModel(
                        scope: .all, captureStore: captureStore, folderStore: folderStore,
                        analysisQueueService: analysisQueueService, searchService: searchService,
                        initialQuery: pending.query),
                    captureStore: captureStore, folderStore: folderStore,
                    analysisQueueService: analysisQueueService, thumbnailLoader: thumbnailLoader
                )
            }
        }
    }

    // 화면설계서 §7.2: "빈 검색어 실행 | 검색 요청 없이 입력 유지".
    private func executeSearch() {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingSearch = PendingSearch(query: trimmed)
    }

    private var header: some View {
        HStack {
            Text("CapPick")
                .font(.system(size: 34, weight: .heavy))
                .tracking(-1.5)
                .foregroundStyle(AppPalette.text)
            Spacer()
            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(AppPalette.text)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("설정")
        }
        .frame(height: 65)
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
            searchArea(progress: progress)
            if progress.total > 0 {
                folderCards(total: progress.total)
            }
        } else if let message = viewModel.errorMessage {
            Text(message).foregroundStyle(.red)
        } else {
            ProgressView()
        }
    }

    // 화면설계서 §7.1 HOME-01 상단 큰 영역 — 안내 문구·작은 분석 상태·검색창을 한 덩어리로 둔다.
    /// 분석 진행 상태(AI-04). 남은 캡처가 있으면 진행 막대와 "N / 전체장 분석 완료"를, 다 끝났으면
    /// 막대 없이 완료 장수만 보여준다. 큐가 멈춰 있으면(분석 대기·한도) 그 안내를 막대 아래에 붙인다.
    @ViewBuilder
    private func analysisStatus(progress: AnalysisProgress) -> some View {
        if progress.total > 0, progress.searchPending > 0 {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(progress.total.formatted())장 중 \(progress.searchReady.formatted())장 분석 완료")
                        .foregroundStyle(AppPalette.secondary)
                    Spacer()
                    Text(viewModel.analysisPauseMessage ?? "분석 중")
                        .fontWeight(.semibold)
                        .foregroundStyle(AppPalette.text)
                }
                .font(.system(size: 12))
                .tracking(-0.2)
                .monospacedDigit()
                MonochromeProgressBar(fraction: Double(progress.searchReady) / Double(progress.total))
            }
            .padding(.bottom, 20)
        } else if progress.total > 0 {
            Text(completedSummary(progress))
                .font(.system(size: 12))
                .tracking(-0.2)
                .foregroundStyle(AppPalette.secondary)
                .padding(.bottom, 20)
        }
    }

    private func completedSummary(_ progress: AnalysisProgress) -> String {
        let done = "\(progress.searchReady.formatted())장 분석 완료"
        return progress.searchFailed > 0 ? done + " · \(progress.searchFailed.formatted())장 실패" : done
    }

    // 하단에는 검색창을 두지 않는다(§7.2 "검색창을 하단으로 옮기지 않음").
    // 시안처럼 별도 "검색" 버튼은 두지 않고 키보드의 검색 키로 실행한다(입력마다 검색하지 않는 규칙은 그대로).
    @ViewBuilder
    private func searchArea(progress: AnalysisProgress) -> some View {
        // 시안 굵기 730/750을 한 단계 위(800)로 둔다 — 한글은 굵기가 정해진 Apple SD Gothic Neo로
        // 그려지고, 시안(웹 미리보기)은 중간 굵기를 받으면 더 굵은 쪽을 고르기 때문(2026-10-15 비교).
        Text("어떤 캡처를 찾고 있나요?")
            .font(.system(size: 26, weight: .heavy))
            .tracking(-1)
            .foregroundStyle(AppPalette.text)
            .padding(.top, 21)
            .padding(.bottom, 18)
        analysisStatus(progress: progress)
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(AppPalette.text)
            TextField("찾고 싶은 스크린샷 검색", text: $searchQuery)
                .font(.system(size: 15))
                .tracking(-0.3)
                .submitLabel(.search)
                .onSubmit { executeSearch() }
        }
        .padding(.horizontal, 13)
        .frame(height: 46)
        .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: AppPalette.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppPalette.radius, style: .continuous)
                .strokeBorder(AppPalette.separator, lineWidth: 1)
        }
    }

    // 화면설계서 HOME-01 카드 목록 — 전체·미분류는 시스템 카드(이름 변경·삭제 없음), 그 뒤가
    // 사용자가 만든 폴더들이다. 폴더가 없어도 전체·미분류는 항상 보인다.
    // 폴더 관리 화면(FOLDER-01)으로 가는 진입점은 이 시안에서 뺐다(2026-10-15 사용자 결정) — 그
    // 화면의 이름·기준 수정, 재분류, 삭제는 각 카드의 ··· 메뉴로 옮겼다.
    @ViewBuilder
    private func folderCards(total: Int) -> some View {
        // 시안: 검색 영역 아래 31pt 뒤 구분선, 그 아래 27pt 뒤 "내 폴더".
        AppPalette.separator.frame(height: 1)
            .padding(.top, 31)
            .padding(.bottom, 27)
        HStack {
            Text("내 폴더")
                .font(.system(size: 24, weight: .heavy))
                .tracking(-0.9)
                .foregroundStyle(AppPalette.text)
            Spacer()
            Button {
                isCreatingFolder = true
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "plus").font(.system(size: 14, weight: .medium))
                    Text("만들기").font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(AppPalette.text)
            }
        }
        .padding(.bottom, 17)
        LazyVGrid(columns: cardColumns, alignment: .leading, spacing: 24) {
            FolderCardView(
                title: "전체", count: total, photoAssetID: viewModel.cardPreviews.all,
                thumbnailLoader: thumbnailLoader) { browseView(scope: .all) }
            FolderCardView(
                title: "미분류", count: viewModel.unclassifiedCount,
                photoAssetID: viewModel.cardPreviews.unclassified,
                thumbnailLoader: thumbnailLoader) { browseView(scope: .unclassified) }
            ForEach(viewModel.folders) { folder in
                FolderCardView(
                    title: folder.displayName, count: viewModel.count(for: folder),
                    photoAssetID: viewModel.cardPreviews.byFolder[folder.id],
                    thumbnailLoader: thumbnailLoader,
                    status: reclassificationStatus(for: folder),
                    destination: { browseView(scope: .folder(folder)) },
                    menu: { folderMenu(folder) })
            }
        }
    }

    @ViewBuilder
    private func folderMenu(_ folder: Folder) -> some View {
        Button("이름 변경", systemImage: "pencil") { editingFolder = folder }
        Button("분류 기준 수정", systemImage: "line.3.horizontal.decrease") { editingFolder = folder }
        Button("기존 캡처 재분류", systemImage: "arrow.triangle.2.circlepath") {
            reclassificationTarget = ReclassificationTarget(folder: folder, mode: .reclassify)
        }
        Button("폴더 삭제", systemImage: "trash", role: .destructive) { folderPendingDeletion = folder }
    }

    /// 기존 캡처 분류가 진행 중이거나 확인을 기다리면 폴더 카드에 한 줄로 알린다.
    private func reclassificationStatus(for folder: Folder) -> String? {
        switch reclassificationCoordinator.job(for: folder.id)?.phase {
        case .running(let done, let total):
            total > 0 ? "분류 중 \(done)/\(total)" : "분류 준비 중"
        case .awaitingConfirmation:
            "재분류 결과 확인 대기"
        case .failed:
            "분류 실패"
        case .finished, .none:
            nil
        }
    }

    private func browseView(scope: BrowseScope) -> some View {
        BrowseView(
            viewModel: BrowseViewModel(
                scope: scope, captureStore: captureStore, folderStore: folderStore,
                analysisQueueService: analysisQueueService, searchService: searchService),
            captureStore: captureStore, folderStore: folderStore,
            analysisQueueService: analysisQueueService, thumbnailLoader: thumbnailLoader,
            // 사용자 폴더 화면에도 홈 카드와 같은 ··· 관리 메뉴를 둔다(2026-10-16 사용자 결정).
            folderManagement: scope.folderID == nil ? nil : BrowseFolderManagement(
                reclassificationCoordinator: reclassificationCoordinator, reclassificationStore: reclassificationStore)
        )
        .onDisappear { Task { await viewModel.refresh() } }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }
}

/// 시안의 얇은 검정 진행 막대 — 기본 ProgressView보다 얇고 끝이 각지다.
private struct MonochromeProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(AppPalette.separator)
                Rectangle()
                    .fill(AppPalette.text)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                    .animation(.easeOut(duration: 0.3), value: fraction)
            }
        }
        .frame(height: 2)
        .accessibilityElement()
        .accessibilityLabel("분석 진행률")
        .accessibilityValue("\(Int((fraction * 100).rounded()))퍼센트")
    }
}
