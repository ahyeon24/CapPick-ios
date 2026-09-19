// ERD v0.2 §2·§3 FolderCapture. Capture-Folder 다대다 연결 + 수동 제거 기록.
// 복합 PK(folder_id, capture_id)라 별도 id 필드가 없다.
struct FolderCapture: Equatable, Codable {
    let folderID: String
    let captureID: String
    var state: FolderCaptureState
    var source: FolderCaptureSource
    var evidence: String?
    var criteriaVersion: Int
    var revision: Int
}

enum FolderCaptureState: String, Codable {
    case present
    case blocked
}

enum FolderCaptureSource: String, Codable {
    case manual
    case auto
}
