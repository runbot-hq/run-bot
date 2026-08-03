// ZIPPrefetchQueue.swift
// RunBotCore
import Foundation
import GitHubClient
import os

/// A single pending prefetch item.
private struct PrefetchItem: Sendable {
    /// The GitHub workflow run ID to fetch.
    let runID: Int
    /// The `owner/repo` scope string for the GitHub API path.
    let scope: String
    /// Whether the run has completed; gates disk cache writes.
    let isCompleted: Bool
}

/// Manages background prefetching of run-level ZIP archives into `DiskZIPCache`.
///
/// Raw ZIP bytes are stored without extraction. Unzipping is deferred to the read path
/// (`LogFetcher.fetchStepLog`) so no CPU work is done for runs the user never opens.
///
/// ## Deduplication
/// `enqueue` is idempotent per `runID`: if the run is already disk-cached
/// or currently in-flight, the call is a no-op.
///
/// ## Concurrency
/// At most `maxConcurrent` (3) fetches run simultaneously. Additional enqueued items
/// wait in `pending` and are drained as slots free up.
///
/// ## Error handling
/// - **nil response** (404, expired ZIP, or transport error): logged and dropped. The run
///   will not be re-enqueued because `RunnerPoller.prefetchedRunIDs` tracks every runID
///   that has been handed to `enqueue`, preventing duplicate calls across poll cycles.
///
/// ## Teardown
/// Call `cancelAll()` when the owning poller is torn down to clear pending work
/// and prevent in-flight background tasks from writing to a deallocated cache.
///
/// `actor`-isolated. All public methods are safe to call from any isolation domain.
public actor ZIPPrefetchQueue {

    // MARK: - Configuration

    /// Maximum number of simultaneous in-flight ZIP fetches.
    public static let maxConcurrent = 3

    // MARK: - Dependencies

    /// Persistent disk cache populated after a successful fetch for completed runs.
    private let diskCache: DiskZIPCache
    /// GitHub transport used to download the ZIP archive.
    private let transport: any GitHubTransportProtocol

    // MARK: - State

    /// runIDs currently being fetched.
    private var inFlight: Set<Int> = []
    /// Items waiting for a free fetch slot.
    private var pending: [PrefetchItem] = []
    /// Number of concurrently running fetch tasks.
    private var activeFetchCount = 0
    /// Set to `true` by `cancelAll()`; prevents further work after teardown.
    private var isCancelled = false

    // MARK: - Init

    /// Creates a prefetch queue backed by the given cache and transport.
    ///
    /// - Parameters:
    ///   - diskCache: Persistent disk cache.
    ///   - transport: GitHub transport for ZIP downloads.
    public init(
        diskCache: DiskZIPCache,
        transport: any GitHubTransportProtocol
    ) {
        self.diskCache = diskCache
        self.transport = transport
    }

    // MARK: - Public API

    /// Enqueues a prefetch for `runID` in `scope`.
    ///
    /// No-op if the run is already present in the disk cache
    /// or currently in-flight. Callers are responsible for not calling `enqueue`
    /// more than once per `runID` across sessions; `RunnerPoller.prefetchedRunIDs`
    /// provides this guarantee for the production call site.
    public func enqueue(runID: Int, scope: String, isCompleted: Bool) async {
        guard !isCancelled else { return }
        guard !inFlight.contains(runID) else { return }
        guard await diskCache.get(runID: runID) == nil else { return }
        guard !pending.contains(where: { $0.runID == runID }) else { return }
        pending.append(PrefetchItem(runID: runID, scope: scope, isCompleted: isCompleted))
        drainQueue()
    }

    /// Clears the pending queue and marks the actor cancelled.
    /// In-flight background tasks check `isCancelled` before writing to caches.
    public func cancelAll() {
        pending.removeAll()
        isCancelled = true
    }

    // MARK: - Private helpers

    /// Starts new fetch tasks up to `maxConcurrent` from the head of `pending`.
    private func drainQueue() {
        while activeFetchCount < Self.maxConcurrent, !pending.isEmpty {
            let item = pending.removeFirst()
            guard !inFlight.contains(item.runID) else { continue }
            inFlight.insert(item.runID)
            activeFetchCount += 1
            let runID = item.runID
            let scope = item.scope
            let isCompleted = item.isCompleted
            Task(priority: .background) { [self] in
                await self.fetch(runID: runID, scope: scope, isCompleted: isCompleted)
            }
        }
    }

    /// Downloads raw ZIP bytes and writes them to disk cache. No unzipping is performed.
    ///
    /// Always removes `runID` from `inFlight` and decrements `activeFetchCount` via `defer`,
    /// regardless of outcome. Calls `drainQueue()` to fill the freed slot.
    private func fetch(runID: Int, scope: String, isCompleted: Bool) async {
        defer {
            inFlight.remove(runID)
            activeFetchCount -= 1
            drainQueue()
        }
        guard !isCancelled else { return }
        log(
            "ZIPPrefetchQueue › fetching ZIP for runID=\(runID) scope='\(scope)' isCompleted=\(isCompleted)",
            category: .services
        )
        guard let data = await transport.raw("repos/\(scope)/actions/runs/\(runID)/logs") else {
            log("ZIPPrefetchQueue › nil response for runID=\(runID) — skipping (ZIP may be expired)", category: .services)
            return
        }
        guard !isCancelled else { return }
        await diskCache.set(runID: runID, zip: data, isCompleted: isCompleted)
        log("ZIPPrefetchQueue › cached \(data.count) bytes for runID=\(runID)", category: .services)
    }
}
