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

    while true {
        let service = IOIteratorNext(iterator)
        guard service != 0 else { return nil }
        let utilisation = gpuUtilisation(of: service)
        IOObjectRelease(service)
        if let utilisation { return utilisation }
    }
}

/// Reads the `PerformanceStatistics` dictionary from a single AGX service and extracts
/// the GPU utilisation percentage.
///
/// - Parameter service: An IOKit service object from the `AGXAccelerator` class.
/// - Returns: A utilisation percentage clamped to 0…100, or `nil` if the property is
///   absent or contains an unrecognised key.
private func gpuUtilisation(of service: io_service_t) -> Double? {
    guard let property = IORegistryEntryCreateCFProperty(
        service,
        "PerformanceStatistics" as CFString,
        kCFAllocatorDefault,
        0
    )?.takeRetainedValue(),
          let statistics = property as? [String: Any] else {
        return nil
    }
    return gpuUtilisation(from: statistics)
}

/// Extracts the GPU utilisation percentage from an AGX `PerformanceStatistics` dictionary.
///
/// Checks for the following registry keys (in order):
///   1. `"Device Utilization %"` — used by Apple Silicon AGXAccelerator drivers.
///   2. `"GPU Activity(%)"` — fallback key seen on some driver versions.
///
/// - Parameter statistics: The `PerformanceStatistics` dictionary from an AGX service.
/// - Returns: A utilisation percentage clamped to 0…100, or `nil` when no recognised key
///   is present or the value is not a valid number.
public func gpuUtilisation(from statistics: [String: Any]) -> Double? {
    let keys = ["Device Utilization %", "GPU Activity(%)"]
    guard let number = keys.lazy.compactMap({ statistics[$0] as? NSNumber }).first else {
        return nil
    }
    return min(100, max(0, number.doubleValue))
}
