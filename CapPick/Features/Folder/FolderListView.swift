import SwiftUI

// 화면설계서 FOLDER-01 폴더 관리. "재분류" 스와이프 액션이 RECLASS-01(재분류 확인)을 연다.
struct FolderListView: View {
    @State private var viewModel: FolderListViewModel
    private let captureStore: any CaptureStoring
    private let folderStore: any FolderStoring
    private let thumbnailLoader: any ThumbnailLoading
    private let analysisQueueService: AnalysisQueueService
    private let searchService: SearchService
    private let reclassificationStore: any ReclassificationStoring
    private let reclassificationService: ReclassificationService

    @State private var isCreatingFolder = false
    @State private var editingFolder: Folder?
    @State private var folderPendingDeletion: Folder?
    @State private var reclassificationTarget: ReclassificationTarget?

    init(
        captureStore: any CaptureStoring, folderStore: any FolderStoring,
        thumbnailLoader: any ThumbnailLoading, analysisQueueService: AnalysisQueueService,
        searchService: SearchService, reclassificationStore: any ReclassificationStoring,
        reclassificationService: ReclassificationService
    ) {
        _viewModel = State(initialValue: FolderListViewModel(folderStore: folderStore, captureStore: captureStore))
        self.captureStore = captureStore
        self.folderStore = folderStore
        self.thumbnailLoader = thumbnailLoader
        self.analysisQueueService = analysisQueueService
        self.searchService = searchService
        self.reclassificationStore = reclassificationStore
        self.reclassificationService = reclassificationService
    }

    var body: some View {
        List {
            Section {
                browseLink(scope: .all) {
                    Label("전체 (\(viewModel.totalCount.formatted())장)", systemImage: "photo.on.rectangle")
                }
                browseLink(scope: .unclassified) {
                    Label("미분류 (\(viewModel.unclassifiedCount.formatted())장)", systemImage: "questionmark.folder")
                }
            }
            Section("내 폴더") {
                if viewModel.folders.isEmpty {
                    Text("직접 폴더를 만들어 캡처를 정리해보세요.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.folders) { folder in
                        browseLink(scope: .folder(folder)) {
                            Text("\(folder.displayName) (\(viewModel.count(for: folder).formatted())장)")
                        }
                        .swipeActions {
                            Button("삭제", role: .destructive) { folderPendingDeletion = folder }
                            Button("수정") { editingFolder = folder }.tint(.gray)
                            Button("재분류") {
                                reclassificationTarget = ReclassificationTarget(folder: folder, mode: .reclassify)
                            }.tint(.black)
                        }
                    }
                }
            }
            if let message = viewModel.errorMessage {
                Text(message).foregroundStyle(.red)
            }
        }
        .navigationTitle("폴더")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("새 폴더", systemImage: "plus") { isCreatingFolder = true }
            }
        }
        .sheet(isPresented: $isCreatingFolder) {
            FolderEditView(viewModel: FolderEditViewModel(
                mode: .create, folderStore: folderStore,
                onSaved: { folder, applyToExisting in
                    Task { await viewModel.load() }
                    if applyToExisting {
                        reclassificationTarget = ReclassificationTarget(folder: folder, mode: .initialApply)
                    }
                }))
        }
        .sheet(item: $editingFolder) { folder in
            FolderEditView(viewModel: FolderEditViewModel(
                mode: .edit(folder), folderStore: folderStore,
                onSaved: { _, _ in Task { await viewModel.load() } }))
        }
        .sheet(item: $reclassificationTarget) { target in
            NavigationStack {
                ReclassificationView(viewModel: ReclassificationViewModel(
                    folder: target.folder, mode: target.mode, reclassificationService: reclassificationService,
                    reclassificationStore: reclassificationStore, captureStore: captureStore,
                    thumbnailLoader: thumbnailLoader))
            }
            .onDisappear { Task { await viewModel.load() } }
        }
        .alert(
            "폴더를 삭제할까요?",
            isPresented: Binding(get: { folderPendingDeletion != nil }, set: { if !$0 { folderPendingDeletion = nil } })
        ) {
            Button("삭제", role: .destructive) {
                if let folder = folderPendingDeletion {
                    Task { await viewModel.delete(folder) }
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("폴더만 삭제돼요. 원본 캡처와 다른 폴더 소속은 유지돼요.")
        }
        .task { await viewModel.load() }
    }

    @ViewBuilder
    private func browseLink(scope: BrowseScope, @ViewBuilder label: () -> some View) -> some View {
        NavigationLink {
            BrowseView(
                viewModel: BrowseViewModel(
                    scope: scope, captureStore: captureStore, folderStore: folderStore,
                    analysisQueueService: analysisQueueService, searchService: searchService),
                captureStore: captureStore, folderStore: folderStore,
                analysisQueueService: analysisQueueService, thumbnailLoader: thumbnailLoader
            )
        } label: {
            label()
        }
    }
}
