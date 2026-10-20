import Foundation
import SnapsiftCore

public enum FolderSessionNotice {
    case scanFinished(items: Int, groups: Int)
    case scanCancelled
    case removed(Int)
    case nothingRemoved
    case putBackDone
}

public enum FolderSessionError {
    case bookmark(Error)
    case scan(Error)
}

/// Ordered problems from the Folder gate, shared sweep, performer and journal.
public enum FolderCommitProblem {
    case withdrawal(FolderGroupWithdrawal, paths: [String])
    case removalFailed(FolderRemovalFailure, path: String)
    case stale(Int)
    case newlyProtected(Int)
    case burstSkipped(Int)
    case unverifiedKept(Int)
    case keeperMissing(Int)
    case survivorsMissing(Int)
    case auditFailed
    case commitFailed(Error)
    case pendingIntent
    case historyFailed(Error)
}

public struct FolderCommitOutcome {
    public let removedCount: Int
    public let problems: [FolderCommitProblem]
}

public enum FolderReconciliationOutcome {
    case recovered(count: Int, unavailable: Int)
    case failed(Error)
}

public enum FolderPutBackProblem {
    case unavailable(FolderHistoryUnavailableReason)
    case locationGrantNeeded(URL)
    case conflict([URL])
    case parentMissing([URL])
    case failed(String)
    case rollbackFailed([URL], String)
    case persistenceFailed(Error)
}

public enum FolderOperationReport {
    case removalIncomplete(FolderCommitOutcome)
    case putBack(FolderPutBackProblem)
    case historyFailed(Error)
}

/// Typed message changes let shells retain the language used when an outcome
/// arrived, including reports that append a later history-read failure.
public enum FolderSessionMessageChange {
    case notice(FolderSessionNotice?)
    case error(FolderSessionError?)
    case recovery(FolderReconciliationOutcome?)
    case operationReport([FolderOperationReport]?)
    case historyReadError(Error?)
}
