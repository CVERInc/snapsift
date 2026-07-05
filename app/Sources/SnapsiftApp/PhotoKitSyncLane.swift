import Foundation
import os

/// The ONE lane for synchronous PhotoKit metadata calls
/// (`PHAsset.adjustmentFormatIdentifier`, `PHAssetResource.assetResources`…).
///
/// Why it exists: those calls are synchronous XPC round-trips into
/// photolibraryd with no timeout of their own. If the daemon restarts
/// mid-call the reply never arrives and the calling thread wedges FOREVER —
/// and every later call convoys behind it on the shared library CoreData
/// queue (live incident 2026-07-03: a scan hung >24 h with all 8 enrich
/// workers — the entire Swift-concurrency cooperative pool — blocked behind
/// one wedged call, with Cancel unreachable). So:
///   • every call runs on this ONE dedicated serial queue — a wedged daemon
///     strands exactly one sacrificial thread, never a cooperative-pool
///     thread, never a growing pile;
///   • every call races a timeout; nil = could not determine, and callers
///     must degrade in their SAFE direction (keep stored values, or
///     over-exclude — never guess the permissive answer);
///   • the first timeout trips a shared breaker (one daemon = one failure
///     domain) and every later call returns nil immediately.
enum PhotoKitSyncLane {

    /// Run one synchronous PhotoKit metadata lookup wedge-proof.
    /// nil = could not determine (timed out, or the breaker already tripped).
    static func call<T: Sendable>(timeoutNs: UInt64 = 10_000_000_000,
                                  _ work: @escaping @Sendable () -> T) async -> T? {
        guard !breaker.isTripped else { return nil }
        let once = ClaimOnce()
        return await withCheckedContinuation { cont in
            lane.async {
                let v = work()
                if once.claim() { cont.resume(returning: v) }
            }
            DispatchQueue.global(qos: .userInitiated)
                .asyncAfter(deadline: .now() + .nanoseconds(Int(timeoutNs))) {
                    if once.claim() {
                        breaker.trip()
                        // The one event worth a Console trace: photolibraryd
                        // stopped answering, one sacrificial thread is now
                        // stranded, and every later lane call degrades.
                        Logger(subsystem: "net.cver.snapsift", category: "photokit-sync-lane")
                            .error("synchronous PhotoKit metadata call timed out — breaker tripped; photolibraryd unresponsive, callers degrade to their safe direction")
                        cont.resume(returning: nil)
                    }
                }
        }
    }

    private static let lane =
        DispatchQueue(label: "net.cver.snapsift.photokit-sync-lane", qos: .userInitiated)
    private static let breaker = Breaker()

    private final class Breaker: @unchecked Sendable {
        private let lock = NSLock()
        private var trippedUntil: DispatchTime = DispatchTime(uptimeNanoseconds: 0)
        /// Trips for 60 s, not for the process lifetime: the failure this
        /// guards against (photolibraryd restarting mid-call) is itself
        /// transient — the daemon is back within seconds. After the cooldown
        /// the next caller probes the lane again; a still-dead daemon re-trips
        /// on that probe's timeout (cost: one timed-out call per minute),
        /// while a recovered one restores edited/paired-video metadata for the
        /// rest of the session instead of silently degrading it for days.
        var isTripped: Bool { lock.lock(); defer { lock.unlock() }; return .now() < trippedUntil }
        func trip() { lock.lock(); trippedUntil = .now() + .seconds(60); lock.unlock() }
    }

    /// First-caller-wins guard so the work block and the timeout can never
    /// both resume the same continuation.
    private final class ClaimOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true; return true
        }
    }
}
