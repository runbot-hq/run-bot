// GPUSampler.swift
// RunBotCore
import Foundation
import IOKit

/// Reads the Apple Silicon GPU's system-wide utilisation percentage by querying the
/// `AGXAccelerator` IOKit service's `PerformanceStatistics["Device Utilization %"]` property.
///
/// Returns `nil` when the AGX service or utilisation property is unavailable (e.g. on
/// non-Apple-Silicon hardware or when the driver does not report this metric).
///
/// - Note: This is a driver-reported 0–100 busy percentage. It may be coarser than
///   `powermetrics` but requires no root privileges, no external process, and is stable
///   across all M-series AGX generations.
/// - Returns: A utilisation percentage clamped to 0…100, or `nil`.
public func sampleGPU() -> Double? {
    guard let matching = IOServiceMatching("AGXAccelerator") else { return nil }
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
        return nil
    }
    defer { IOObjectRelease(iterator) }

    var service = IOIteratorNext(iterator)
    while service != 0 {
        defer { IOObjectRelease(service) }
        if let property = IORegistryEntryCreateCFProperty(
            service,
            "PerformanceStatistics" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue(),
           let statistics = property as? [String: Any],
           let number = statistics["Device Utilization %"] as? NSNumber {
            return min(100, max(0, number.doubleValue))
        }
        service = IOIteratorNext(iterator)
    }
    return nil
}
