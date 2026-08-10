// ZIPPrefetchQueue.swift
// RunBotCore
import Foundation
import GitHubClient
import os

/// A single pending prefetch item.
private struct PrefetchItem: Sendable {
    /// The ZIP cache entry key (group + runID + runAttempt).
    let entryKey: ZIPCacheEntryKey
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
/// `enqueue` is idempotent per `ZIPCacheEntryKey`: if the entry is already disk-cached
/// or currently in-flight, the call is a no-op.
///
/// ## Concurrency
/// At most `maxConcurrent` (3) fetches run simultaneously. Additional enqueued items
/// wait in `pending` and are drained as slots free up.
///
/// ## Error handling
/// - **nil response** (404, expired ZIP, or transport error): logged and dropped.
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

    /// Entry keys currently being fetched.
    private var inFlight: Set<ZIPCacheEntryKey> = []
    /// Items waiting for a free fetch slot.
    private var pending: [PrefetchItem] = []
    /// Number of concurrently running fetch tasks.
    private var activeFetchCount = 0
    /// Set to `true` by `cancelAll()`; prevents further work after teardown.
    private var isCancelled = false

    // MARK: - Init

    public init(
        diskCache: DiskZIPCache,
        transport: any GitHubTransportProtocol
    ) {
        self.diskCache = diskCache
        self.transport = transport
    }

    // MARK: - Public API

    /// Enqueues a prefetch for `entryKey`.
    ///
    /// No-op if the entry is already present in the disk cache or currently in-flight.
    public func enqueue(entryKey: ZIPCacheEntryKey, scope: String, isCompleted: Bool) async {
        guard !isCancelled else { return }
        guard !inFlight.contains(entryKey) else { return }
        guard diskCache.get(key: entryKey) == nil else { return }
        guard !pending.contains(where: { $0.entryKey == entryKey }) else { return }
        pending.append(PrefetchItem(entryKey: entryKey, scope: scope, isCompleted: isCompleted))
        drainQueue()
    }

    /// Clears the pending queue and marks the actor cancelled.
    public func cancelAll() {
        pending.removeAll()
        isCancelled = true
    }

    // MARK: - Private helpers

    private func drainQueue() {
        while activeFetchCount < Self.maxConcurrent, !pending.isEmpty {
            let item = pending.removeFirst()
            guard !inFlight.contains(item.entryKey) else { continue }
            inFlight.insert(item.entryKey)
            activeFetchCount += 1
            let entryKey = item.entryKey
            let scope = item.scope
            let isCompleted = item.isCompleted
            Task(priority: .background) { [self] in
                await self.fetch(entryKey: entryKey, scope: scope, isCompleted: isCompleted)
            }
        }
    }

    private func fetch(entryKey: ZIPCacheEntryKey, scope: String, isCompleted: Bool) async {
        defer {
            inFlight.remove(entryKey)
            activeFetchCount -= 1
            drainQueue()
        }
        guard !isCancelled else { return }
        log(
            "ZIPPrefetchQueue › fetching ZIP for runID=\(entryKey.runID) attempt=\(entryKey.runAttempt) scope='\(scope)' isCompleted=\(isCompleted)",
            category: .services
        )
        guard let data = await transport.raw("repos/\(scope)/actions/runs/\(entryKey.runID)/logs") else {
            log("ZIPPrefetchQueue › nil response for runID=\(entryKey.runID) — skipping (ZIP may be expired)", category: .services)
            return
        }
        guard !isCancelled else { return }
        diskCache.set(key: entryKey, zip: data, isCompleted: isCompleted)
        log(
            "ZIPPrefetchQueue › stored ZIP for runID=\(entryKey.runID) attempt=\(entryKey.runAttempt) bytes=\(data.count)",
            category: .services
        )
    }
}
