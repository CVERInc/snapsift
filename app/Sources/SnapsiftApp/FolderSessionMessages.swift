import Foundation
import SnapsiftFolder

extension FolderSessionNotice {
    func message(_ t: L10n) -> String {
        switch self {
        case .scanFinished(let items, let groups): return t.folderScanFinished(items: items, groups: groups)
        case .scanCancelled: return t.folderScanCancelled()
        case .removed(let count): return t.folderRemoved(count)
        case .nothingRemoved: return t.folderNothingRemoved()
        case .putBackDone: return t.folderPutBackDone()
        }
    }
}

extension FolderSessionError {
    func message(_ t: L10n) -> String {
        switch self {
        case .bookmark(let error): return t.folderBookmarkError(error.localizedDescription)
        case .scan(let error): return t.folderScanError(error.localizedDescription)
        }
    }
}

extension FolderCommitProblem {
    func message(_ t: L10n) -> String {
        switch self {
        case .withdrawal(let withdrawal, let paths):
            return ([t.folderWithdrawalReport(withdrawal.itemCount, reason: withdrawal.reason)] + paths).joined(separator: "\n")
        case .removalFailed(let failure, let path): return "\(path)\n\(t.folderRemovalFailure(failure.reason))"
        case .stale(let count): return t.folderStale(count)
        case .newlyProtected(let count): return t.folderNewlyProtected(count)
        case .burstSkipped(let count): return t.commitBurstSkipped(count)
        case .unverifiedKept(let count): return t.folderUnverifiedKept(count)
        case .keeperMissing(let count): return t.folderKeeperMissing(count)
        case .survivorsMissing(let count): return t.folderSurvivorsMissing(count)
        case .auditFailed: return t.folderAuditFailed()
        case .commitFailed(let error): return t.folderCommitError(error)
        case .pendingIntent: return t.folderPendingIntent()
        case .historyFailed(let error): return t.folderHistoryFailed(error.localizedDescription)
        }
    }
}

extension FolderReconciliationOutcome {
    func message(_ t: L10n) -> String {
        switch self {
        case .recovered(let count, let unavailable): return t.folderRecovered(count, unavailable: unavailable)
        case .failed(let error): return t.folderReconcileFailed(error.localizedDescription)
        }
    }
}

extension FolderOperationReport {
    func message(_ t: L10n) -> String {
        switch self {
        case .removalIncomplete(let outcome):
            return ([t.folderRemovalIncomplete(outcome.removedCount)] + outcome.problems.map { $0.message(t) }).joined(separator: "\n\n")
        case .putBack(let problem): return problem.message(t)
        case .historyFailed(let error): return t.folderHistoryFailed(error.localizedDescription)
        }
    }
}

extension FolderPutBackProblem {
    func message(_ t: L10n) -> String {
        switch self {
        case .unavailable(let reason): return t.folderHistoryUnavailable(reason)
        case .conflict(let urls): return t.folderPutBackConflict(urls)
        case .parentMissing(let urls): return t.folderPutBackParentMissing(urls)
        case .failed(let detail): return t.folderPutBackFailed(detail)
        case .rollbackFailed(let urls, let detail): return t.folderPutBackPartial(urls, detail: detail)
        case .persistenceFailed(let error): return t.folderPutBackPersistenceFailed(error.localizedDescription)
        }
    }
}
