import Foundation

/// Progress of a `refreshAll`, for the UI's spinner and "updated X ago" line.
public enum RefreshProgress: Sendable, Hashable {
    /// The refresh claimed `last_refresh_at` (= `at`) and is about to fetch `total` sources.
    case started(at: Date, total: Int)
    /// One source finished (ok or failed). `completed` counts finished sources so far.
    case sourceFinished(SourceRefreshResult, completed: Int, total: Int)
    /// Always the last event. `result.ran == false` when skipped by the 15-minute stale rule.
    case finished(RefreshResult)
}

/// A RefreshService that can report progress while it runs. `DefaultRefreshService` conforms.
public protocol RefreshProgressReporting: Sendable {
    func refreshAll(force: Bool, progress: @escaping @Sendable (RefreshProgress) -> Void) async throws -> RefreshResult
}

extension RefreshService {
    /// refreshAll with progress callbacks (called off the main actor, in order). Services that don't
    /// implement `RefreshProgressReporting` only report `.finished`.
    public func refreshAll(force: Bool, progress: @escaping @Sendable (RefreshProgress) -> Void) async throws -> RefreshResult {
        if let reporting = self as? any RefreshProgressReporting {
            return try await reporting.refreshAll(force: force, progress: progress)
        }
        let r = try await refreshAll(force: force)
        progress(.finished(r))
        return r
    }

    /// The same as a stream: `.started`, one `.sourceFinished` per source, then `.finished`; it throws if
    /// the refresh itself fails (per-source errors are reported in the results, not thrown). Cancelling
    /// the consuming task cancels the refresh.
    public func refreshUpdates(force: Bool) -> AsyncThrowingStream<RefreshProgress, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await self.refreshAll(force: force) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
