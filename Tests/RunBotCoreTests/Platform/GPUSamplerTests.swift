// GPUSamplerTests.swift
// RunBotCoreTests
import Foundation
import RunBotCore
import Testing

// MARK: - gpuUtilisation(from:)

@Suite("gpuUtilisation(from:)")
struct GPUSamplerTests {

    /// Parses the primary "Device Utilization %" key from a performance statistics dictionary.
    @Test func parsesDeviceUtilizationPercent() {
        let stats = ["Device Utilization %": NSNumber(value: 42.5)]
        #expect(gpuUtilisation(from: stats) == 42.5)
    }

    /// Falls back to the alternate "GPU Activity(%)" key when the primary key is absent.
    @Test func fallsBackToGPUActivityKey() {
        let stats = ["GPU Activity(%)": NSNumber(value: 78.0)]
        #expect(gpuUtilisation(from: stats) == 78.0)
    }

    /// Prefers "Device Utilization %" over "GPU Activity(%)" when both keys are present.
    @Test func prefersDeviceUtilizationOverGPUActivity() {
        let stats: [String: Any] = [
            "Device Utilization %": NSNumber(value: 30.0),
            "GPU Activity(%)": NSNumber(value: 90.0)
        ]
        #expect(gpuUtilisation(from: stats) == 30.0)
    }

    /// Returns `nil` when the dictionary contains neither recognised key.
    @Test func missingKeyReturnsNil() {
        let stats = ["UnrelatedKey": NSNumber(value: 50)]
        #expect(gpuUtilisation(from: stats) == nil)
    }

    /// Returns `nil` when the dictionary is empty.
    @Test func emptyDictionaryReturnsNil() {
        let stats: [String: Any] = [:]
        #expect(gpuUtilisation(from: stats) == nil)
    }

    /// Returns `nil` when the value for a recognised key is not an `NSNumber`
    /// (e.g. a string or array).
    @Test func invalidValueTypeReturnsNil() {
        let stats = ["Device Utilization %": "not-a-number"]
        #expect(gpuUtilisation(from: stats) == nil)
    }

    /// Clamps values above 100 down to 100.
    @Test func clampsValuesAbove100() {
        let stats = ["Device Utilization %": NSNumber(value: 150.0)]
        #expect(gpuUtilisation(from: stats) == 100.0)
    }

    /// Clamps values below 0 up to 0.
    @Test func clampsValuesBelow0() {
        let stats = ["Device Utilization %": NSNumber(value: -10.0)]
        #expect(gpuUtilisation(from: stats) == 0.0)
    }

    /// Returns 0.0 when the value is exactly 0.
    @Test func zeroUtilisationReturnsZero() {
        let stats = ["Device Utilization %": NSNumber(value: 0.0)]
        #expect(gpuUtilisation(from: stats) == 0.0)
    }

    /// Ignores unrelated registry fields that may appear alongside the GPU key.
    @Test func ignoresUnrelatedRegistryFields() {
        let stats: [String: Any] = [
            "Device Utilization %": NSNumber(value: 55.0),
            "GPUTime": NSNumber(value: 1234),
            "Core Utilization": "some string",
            "gpuCoreCount": NSNumber(value: 8)
        ]
        #expect(gpuUtilisation(from: stats) == 55.0)
    }

    /// Returns `nil` for `NaN`, positive infinity, and negative infinity so invalid
    /// telemetry follows the unavailable path rather than clamping to 0% or 100%.
    @Test(arguments: [
        Double.nan,
        Double.infinity,
        -Double.infinity
    ])
    func nonFiniteValueReturnsNil(_ value: Double) {
        let stats = ["Device Utilization %": NSNumber(value: value)]
        #expect(gpuUtilisation(from: stats) == nil)
    }
}
