import Observation

// 화면설계서 FOLDER-01. 전체·미분류는 시스템 보기라 이름 변경·삭제 메뉴가 없다(§10.1) — 사용자
// 폴더만 그 대상이다.
@MainActor @Observable
final class FolderListViewModel {
    private(set) var folders: [Folder] = []
    private(set) var totalCount = 0
    private(set) var unclassifiedCount = 0
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private var folderCounts: [String: Int] = [:]

    private let folderStore: any FolderStoring
    private let captureStore: any CaptureStoring

    init(folderStore: any FolderStoring, captureStore: any CaptureStoring) {
        self.folderStore = folderStore
        self.captureStore = captureStore
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        do {
            folders = try await folderStore.fetchAll()
            folderCounts = try await captureStore.fetchFolderCaptureCounts()
            totalCount = try await captureStore.currentProgress().total
            unclassifiedCount = try await captureStore.unclassifiedCount()
        } catch {
            errorMessage = "폴더를 불러오지 못했어요."
        }
    }

    /// 소속 캡처가 0장인 폴더는 fetchFolderCaptureCounts() 결과에 키 자체가 없다.
    func count(for folder: Folder) -> Int {
        folderCounts[folder.id] ?? 0
    }

    /// 삭제 확인("폴더만 삭제돼요. 원본 캡처와 다른 폴더 소속은 유지돼요.")은 View가 보여준 뒤 부른다.
    func delete(_ folder: Folder) async {
        errorMessage = nil
        do {
            try await folderStore.delete(id: folder.id)
            await load()
        } catch {
            errorMessage = "폴더를 삭제하지 못했어요."
        }
    }
}
