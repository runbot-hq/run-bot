// MBKOverlayGateTests.swift
// MenuBarKitTests

import Testing
@testable import MenuBarKit

/// Tests for MBKOverlayGate — the single Bool that blocks popover dismiss
/// while any overlay (sheet or file picker) is live.
@MainActor
struct MBKOverlayGateTests {

    // MARK: - Initial state

    @Test func initialStateIsNotActive() {
        let gate = MBKOverlayGate()
        #expect(gate.hasActiveOverlay == false)
    }

    // MARK: - Setting the flag

    @Test func settingTrueReflectsImmediately() {
        let gate = MBKOverlayGate()
        gate.hasActiveOverlay = true
        #expect(gate.hasActiveOverlay == true)
    }

    @Test func settingFalseAfterTrueReflectsImmediately() {
        let gate = MBKOverlayGate()
        gate.hasActiveOverlay = true
        gate.hasActiveOverlay = false
        #expect(gate.hasActiveOverlay == false)
    }

    @Test func idempotentTrue() {
        let gate = MBKOverlayGate()
        gate.hasActiveOverlay = true
        gate.hasActiveOverlay = true
        #expect(gate.hasActiveOverlay == true)
    }

    @Test func idempotentFalse() {
        let gate = MBKOverlayGate()
        gate.hasActiveOverlay = false
        #expect(gate.hasActiveOverlay == false)
    }

    // MARK: - Independence

    @Test func twoGatesAreIndependent() {
        let gateA = MBKOverlayGate()
        let gateB = MBKOverlayGate()
        gateA.hasActiveOverlay = true
        #expect(gateA.hasActiveOverlay == true)
        #expect(gateB.hasActiveOverlay == false)
    }
}
