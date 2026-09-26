import Foundation
@testable import CapPick

final class FakeUsageAPIClient: UsageAPIClient, @unchecked Sendable {
    var usageResult: Result<UsageSummary, Error> = .success(UsageSummary(categories: [
        UsageCategorySummary(
            category: .contentAnalysis, usedUnits: 3, reservedUnits: 1,
            limitUnits: nil, resetsAt: nil, canSubmit: true),
        UsageCategorySummary(
            category: .classification, usedUnits: 2, reservedUnits: 0,
            limitUnits: nil, resetsAt: nil, canSubmit: true),
    ]))

    private(set) var fetchCallCount = 0

    func fetchUsage(credential: String) async throws -> UsageSummary {
        fetchCallCount += 1
        return try usageResult.get()
    }
}

final class FakeDeletionAPIClient: DeletionAPIClient, @unchecked Sendable {
    var requestResult: Result<DeletionSubmitted, Error> = .success(
        DeletionSubmitted(deletionId: "d1", status: .pending))
    var statusResult: Result<DeletionStatusResult, Error> = .success(
        DeletionStatusResult(deletionId: "d1", status: .completed, completedAt: Date(timeIntervalSince1970: 1_000), errorCode: nil))

    private(set) var requestCallCount = 0
    private(set) var requestedIdempotencyKeys: [String] = []

    func requestInstallationDeletion(credential: String, idempotencyKey: String) async throws -> DeletionSubmitted {
        requestCallCount += 1
        requestedIdempotencyKeys.append(idempotencyKey)
        return try requestResult.get()
    }

    func fetchDeletionStatus(deletionId: String, credential: String) async throws -> DeletionStatusResult {
        try statusResult.get()
    }
}
