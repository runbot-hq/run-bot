// SystemStatsViewModel.swift
// RunBot
@preconcurrency import Darwin
import Foundation
import Observation
import RunBotCore

// MARK: - SystemStatsViewModel
/// Observable view-model that periodically samples CPU, GPU, memory, and disk metrics.
/// Call `start()` when the owning view appears and `stop()` when it disappears.
@MainActor
@Observable
final class SystemStatsViewModel {
    /// Latest sampled snapshot, ready for display.
    private(set) var stats: SystemStats = .zero
    /// Rolling 60-sample history for CPU sparkline charts.
    private(set) var cpuHistory: RingBuffer = RingBuffer(capacity: 60)
    /// Rolling 60-sample history for memory-usage sparkline charts.
    private(set) var memHistory: RingBuffer = RingBuffer(capacity: 60)
    /// Rolling 60-sample history for GPU-utilisation sparkline charts.
    private(set) var gpuHistory: RingBuffer = RingBuffer(capacity: 60)
    /// Rolling 60-sample history for disk-usage sparkline charts.
    private(set) var diskHistory: RingBuffer = RingBuffer(capacity: 60)
    /// Structured task driving the 2-second sample loop.
    /// Cancelled and niled in `stop()` and `deinit`; `@ObservationIgnored` keeps it out of
    /// the `@Observable` macro’s tracking storage.
    @ObservationIgnored private var samplingTask: Task<Void, Never>?
    /// Liveness flag for the sample loop, decoupled from `samplingTask`.
    ///
    /// `samplingTask` is the cancellation handle only. `isSampling` is the single
    /// source of truth for whether the loop is running. Keeping them separate means
    /// a caller that calls `samplingTask?.cancel()` directly (without niling) cannot
    /// make `start()` silently no-op on a loop that has already exited.
    ///
    /// Both `start()` and the task body itself reset this flag: `start()` sets it
    /// `true`, the task’s `defer` sets it `false` on every exit path, and `stop()`
    /// sets it `false` via cancellation. The `defer` is generation-stamped so a
    /// stale task exiting after a rapid `stop()→start()` cannot reset `isSampling`
    /// on the newly started loop.
    private var isSampling = false
    /// Monotonically increasing counter incremented on every `start()` call.
    ///
    /// Each task closure captures its own generation value at launch. The `defer`
    /// block only resets `isSampling` when the captured generation still matches
    /// `samplingGeneration`, i.e. no newer `start()` has run since this task began.
    /// This prevents a stale task’s `defer` from permanently no-opping future
    /// `start()` calls after a rapid `stop()→start()` cycle.
    private var samplingGeneration: Int = 0
    /// Per-core CPU tick counts from the previous `host_processor_info` call.
    ///
    /// Written exclusively on `@MainActor` (inside `sampleCPU()`’s `defer` block).
    /// `nonisolated(unsafe)` is required because `deinit` is nonisolated in Swift 6
    /// and must read this pointer to pass to `deallocBuffer(_:count:)` — crossing
    /// into `@MainActor` asynchronously from `deinit` is not possible. This is safe
    /// because `deinit` only runs after all strong references are gone, guaranteeing
    /// no concurrent `@MainActor` write can occur at that point.
    @ObservationIgnored nonisolated(unsafe) private var prevCPUInfo: processor_info_array_t?
    /// Entry count of `prevCPUInfo`, required by `vm_deallocate` for correct deallocation size.
    /// Same `nonisolated(unsafe)` rationale as `prevCPUInfo`.
    @ObservationIgnored nonisolated(unsafe) private var prevNumCPUInfo: mach_msg_type_number_t = 0
    /// Root volume path used for disk-space queries via `FileManager.attributesOfFileSystem`.
    private static let rootVolumePath = NSOpenStepRootDirectory()

    /// Creates a new instance; all properties are default-initialised.
    init() { /* no custom setup required — all stored properties have default values */ }

    deinit {
        // Task.cancel() is safe to call from any isolation context — no DispatchQueue hop needed.
        samplingTask?.cancel()
        // Capture pointer and count as locals before calling the nonisolated static helper.
        // deallocPrevCPUInfo() is @MainActor-isolated and unreachable from nonisolated deinit;
        // deallocBuffer(_:count:) takes values by copy, requires no actor hop, no duplication.
        SystemStatsViewModel.deallocBuffer(prevCPUInfo, count: prevNumCPUInfo)
    }

    // MARK: Lifecycle

    /// Starts the 2-second structured sample loop and takes an immediate first sample.
    /// Safe to call multiple times — no-ops if the loop is already running.
    ///
    /// `isSampling` is the liveness guard; `samplingTask` is the cancellation handle only.
    /// This separation ensures that a direct `samplingTask?.cancel()` call (without niling)
    /// cannot make `start()` silently no-op on a loop that has already exited.
    ///
    /// The task captures `generation` at launch. The `defer` only resets `isSampling` when
    /// the captured generation still matches `samplingGeneration` — preventing a stale
    /// exiting task from no-opping a freshly started loop after a rapid `stop()→start()`.
    ///
    /// `Task { @MainActor [weak self] in }` is used rather than the bare `Task { [weak self] in }`
    /// to make the `@MainActor` isolation explicit. A bare `Task { }` created from an
    /// `@MainActor`-isolated context does inherit `@MainActor` today, but the annotation
    /// anchors that guarantee against a future refactor that moves `start()` off `@MainActor`.
    func start() {
        guard !isSampling else { return }
        isSampling = true
        samplingGeneration &+= 1
        let generation = samplingGeneration
        samplingTask = Task { @MainActor [weak self] in
            defer {
                // Only reset isSampling if this is still the current generation.
                // A stale task exiting after a rapid stop→start must not clobber
                // the liveness flag owned by the newer task.
                if self?.samplingGeneration == generation {
                    self?.isSampling = false
                }
            }
            // Immediate first sample before the first sleep.
            self?.sample()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch is CancellationError {
                    break   // clean cooperative cancellation — exit silently
                } catch {
                    break   // unexpected error — exit defensively
                }
                guard !Task.isCancelled else { break }
                self?.sample()
            }
        }
    }

    /// Cancels the sampling loop immediately. Call from `onDisappear`.
    func stop() {
        samplingTask?.cancel()
        samplingTask = nil
        isSampling = false
    }

    // MARK: Sampling
    /// Collects CPU, GPU, memory, and disk snapshots and publishes updated stats and history buffers.
    private func sample() {
        let cpu = sampleCPU()
        let gpu = sampleGPU()
        let mem = sampleMemory()
        let disk = sampleDisk()
        let snapshot = SystemStats(
            cpuPct: cpu,
            gpuPct: gpu,
            memUsedGB: mem.used,
            memTotalGB: mem.total,
            diskUsedGB: disk.used,
            diskTotalGB: disk.total
        )
        var newCPU = cpuHistory
        var newGPU = gpuHistory
        var newMem = memHistory
        var newDisk = diskHistory
        newCPU.append(cpu)
        if let gpu { newGPU.append(gpu) }
        let memPct = mem.total > 0 ? mem.used / mem.total * 100 : 0.0
        let diskPct = disk.total > 0 ? disk.used / disk.total * 100 : 0.0
        newMem.append(memPct)
        newDisk.append(diskPct)
        self.stats = snapshot
        self.cpuHistory = newCPU
        self.gpuHistory = newGPU
        self.memHistory = newMem
        self.diskHistory = newDisk
    }

    // MARK: CPU
    // Mach host_processor_info diff loop — cannot be extracted without losing clarity.
    /// Reads per-core tick counts via `host_processor_info` and returns aggregate CPU usage (0-100).
    /// Diffs against the previous sample; returns `0` on the first call or if the kernel call fails.
    private func sampleCPU() -> Double {
        var numCPUsU: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUsU, &cpuInfo, &numCPUInfo)
        guard kr == KERN_SUCCESS, let cpuInfo else { return 0 }
        defer {
            deallocPrevCPUInfo()
            prevCPUInfo = cpuInfo
            prevNumCPUInfo = numCPUInfo
        }
        guard let prevInfo = prevCPUInfo else { return 0 }
        var totalUsed: Double = 0
        var totalAll: Double = 0
        let numCPUs = Int(numCPUsU)
        for i in 0 ..< numCPUs {
            let base = Int(CPU_STATE_MAX) * i
            let userDelta = Double(cpuInfo[base + Int(CPU_STATE_USER)] - prevInfo[base + Int(CPU_STATE_USER)])
            let sysDelta = Double(cpuInfo[base + Int(CPU_STATE_SYSTEM)] - prevInfo[base + Int(CPU_STATE_SYSTEM)])
            let idleDelta = Double(cpuInfo[base + Int(CPU_STATE_IDLE)] - prevInfo[base + Int(CPU_STATE_IDLE)])
            let niceDelta = Double(cpuInfo[base + Int(CPU_STATE_NICE)] - prevInfo[base + Int(CPU_STATE_NICE)])
            let used = userDelta + sysDelta + niceDelta
            totalUsed += used
            totalAll += used + idleDelta
        }
        guard totalAll > 0 else { return 0 }
        return totalUsed / totalAll * 100
    }

    /// Frees the current `prevCPUInfo` Mach buffer and nils the pointer.
    /// Called from `sampleCPU()`’s `defer` block (always on `@MainActor`).
    /// Delegates to `deallocBuffer(_:count:)` so the deallocation logic lives in one place.
    private func deallocPrevCPUInfo() {
        let ptr = prevCPUInfo
        let count = prevNumCPUInfo
        prevCPUInfo = nil
        SystemStatsViewModel.deallocBuffer(ptr, count: count)
    }

    /// Frees a Mach `processor_info_array_t` buffer obtained from `host_processor_info`.
    ///
    /// This helper is `private static nonisolated` so it can be called from both
    /// the `@MainActor`-isolated `deallocPrevCPUInfo()` (hot path) and the
    /// nonisolated `deinit` (cleanup path) without duplication or an actor hop.
    /// The pointer and count are passed by value — no instance state is read.
    ///
    /// - Parameters:
    ///   - ptr: The `processor_info_array_t` returned by `host_processor_info`, or `nil`.
    ///   - count: The `mach_msg_type_number_t` entry count returned alongside `ptr`.
    private static nonisolated func deallocBuffer(
        _ ptr: processor_info_array_t?,
        count: mach_msg_type_number_t
    ) {
        guard let ptr else { return }
        let size = vm_size_t(MemoryLayout<integer_t>.size) * vm_size_t(count)
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: ptr), size)
    }

    // MARK: Memory
    /// Queries `host_statistics64` for `HOST_VM_INFO64` and converts page counts to gigabytes.
    /// - Returns: `(used, total)` in GB where `used` counts active + wired + compressor pages.
    private func sampleMemory() -> (used: Double, total: Double) {
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vmStats) { vmStatsPtr in
            vmStatsPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        let pageSize = Double(Int(vm_kernel_page_size))
        let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)
        let totalGB = totalBytes / 1_000_000_000
        guard kr == KERN_SUCCESS else { return (0, totalGB) }
        let usedPages = Double(vmStats.active_count + vmStats.wire_count + vmStats.compressor_page_count)
        let usedGB = usedPages * pageSize / 1_000_000_000
        return (usedGB, totalGB)
    }

    // MARK: Disk
    /// Reads total and free bytes for the root volume and returns used/total in GB.
    /// - Returns: `(used, total)` in GB, or `(0, 0)` if the file-system query fails.
    /// - Note: Casts to `Int64`; safe for volumes up to ~9.2 EB. If Apple Silicon Macs ever
    ///   ship volumes exceeding `Int64.max`, migrate to `UInt64` casts here.
    private func sampleDisk() -> (used: Double, total: Double) {
        guard
            let attrs = try? FileManager.default.attributesOfFileSystem(forPath: Self.rootVolumePath),
            let total = attrs[.systemSize] as? Int64,
            let free = attrs[.systemFreeSize] as? Int64
        else { return (0, 0) }
        let totalGB = Double(total) / 1_000_000_000
        let usedGB = Double(total - free) / 1_000_000_000
        return (usedGB, totalGB)
    }
}
