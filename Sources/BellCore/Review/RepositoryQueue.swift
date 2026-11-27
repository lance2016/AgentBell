import Foundation

/// Runs work on a repository's refs and worktrees one piece at a time, so concurrent
/// reviews of one repository do not race for Git's locks.
actor RepositoryQueue {
    static let shared = RepositoryQueue()
    private var tails: [String: Task<Void, Never>] = [:]

    /// Cancelling the caller cancels the work.
    func run<T: Sendable>(_ repository: URL, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = enqueue(repository, work)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Cleanup: runs to the end even when the caller was cancelled, which is when it is needed.
    func run(_ repository: URL, _ work: @escaping @Sendable () async -> Void) async {
        _ = try? await enqueue(repository) { () async throws -> Bool in
            await work()
            return true
        }.value
    }

    private func enqueue<T: Sendable>(
        _ repository: URL, _ work: @escaping @Sendable () async throws -> T
    ) -> Task<T, Error> {
        let key = repository.standardizedFileURL.resolvingSymlinksInPath().path
        let previous = tails[key]
        let task = Task<T, Error> {
            await previous?.value
            return try await work()
        }
        tails[key] = Task { _ = try? await task.value }
        return task
    }
}
