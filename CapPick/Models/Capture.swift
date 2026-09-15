import Foundation

// ERD v0.2 §2 Capture, §3 상태 규칙 기준.
struct Capture: Identifiable, Equatable {
    let id: String
    let photoAssetID: String
    let capturedAt: Date
    let width: Int
    let height: Int
    var availability: CaptureAvailability
    var excludedAt: Date?
    var favorite: Bool
    var contentRevision: Int
    var searchState: SearchState
    var classificationState: ClassificationState
}

enum CaptureAvailability: String, Codable {
    case accessible
    case unavailable
}

enum SearchState: String, Codable {
    case pending
    case processing
    case ready
    case failed
}

enum ClassificationState: String, Codable {
    case pending
    case processing
    case complete
    case failed
    case blocked
}
