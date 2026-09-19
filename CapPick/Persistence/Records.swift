import GRDB

extension Capture: FetchableRecord, PersistableRecord {
    static let databaseTableName = "capture"
}

extension CaptureAnalysis: FetchableRecord, PersistableRecord {
    static let databaseTableName = "captureAnalysis"
}

extension SearchDocument: FetchableRecord, PersistableRecord {
    static let databaseTableName = "searchDocument"
}

extension Folder: FetchableRecord, PersistableRecord {
    static let databaseTableName = "folder"
}

extension FolderCapture: FetchableRecord, PersistableRecord {
    static let databaseTableName = "folderCapture"
}

extension LocalTask: FetchableRecord, PersistableRecord {
    static let databaseTableName = "localTask"
}

extension ReclassificationRun: FetchableRecord, PersistableRecord {
    static let databaseTableName = "reclassificationRun"
}

extension ReclassificationItem: FetchableRecord, PersistableRecord {
    static let databaseTableName = "reclassificationItem"
}

extension AppStateEntry: FetchableRecord, PersistableRecord {
    static let databaseTableName = "appState"
}
