// SystemStats.swift
// RunBotCore
import Foundation

/// Snapshot of CPU and memory metrics sampled at a point in time.
public struct SystemStats: Sendable, Equatable {
    /// CPU usage percentage (0–100).
    public let cpuPct: Double
    /// Used memory in gigabytes.
    public let memUsedGB: Double
    /// Total physical memory in gigabytes.
    public let memTotalGB: Double
    /// Used disk space in gigabytes.
    public let diskUsedGB: Double
    /// Total disk space in gigabytes.
    public let diskTotalGB: Double

    /// Creates a new `SystemStats` snapshot with the given metric values.
    public init(
        cpuPct: Double,
        memUsedGB: Double,
        memTotalGB: Double,
        diskUsedGB: Double,
        diskTotalGB: Double
    ) {
        self.cpuPct = cpuPct
        self.memUsedGB = memUsedGB
        self.memTotalGB = memTotalGB
        self.diskUsedGB = diskUsedGB
        self.diskTotalGB = diskTotalGB
    }

    /// Memory pressure as a fraction in 0…1.
    public var memoryPressure: Double {
        guard memTotalGB > 0 else { return 0 }
        return memUsedGB / memTotalGB
    }

    /// Disk usage as a fraction in 0…1.
    public var diskPressure: Double {
        guard diskTotalGB > 0 else { return 0 }
        return diskUsedGB / diskTotalGB
    }

    /// Percentage of disk space that is FREE (0–100).
    public var diskFreePct: Double {
        guard diskTotalGB > 0 else { return 0 }
        return ((diskTotalGB - diskUsedGB) / diskTotalGB) * 100
    }

    /// Zero-initialised snapshot used as the default before the first sample arrives.
    public static let zero = SystemStats(
        cpuPct: 0, memUsedGB: 0, memTotalGB: 0, diskUsedGB: 0, diskTotalGB: 0
    )
}
