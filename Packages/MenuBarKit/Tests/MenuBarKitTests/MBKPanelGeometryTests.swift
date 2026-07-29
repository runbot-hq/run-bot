// MBKPanelGeometryTests.swift
// MenuBarKitTests
//
// Pure-math coverage for the panel frame pipeline. No AppKit, no NSApplication,
// no window server — everything here is CGRect arithmetic, so these tests are
// the regression guard for #2278/#2279 (stale geometry, clipped arrow).

import CoreGraphics
import SwiftUI
import Testing
@testable import MenuBarKit

struct MBKPanelGeometryTests {

    /// Visible frame of a standard 1440×900 display with a 25pt menu bar.
    /// This is the *visible* frame (875pt tall), not the full screen frame (900pt).
    /// Tests that need the full screen frame construct it inline as CGRect(x:0, y:0, width:1440, height:900).
    private let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let metrics = MBKPanelMetrics.default

    // MARK: - Window size

    @Test func windowSizeAddsArrowHeight() {
        let size = MBKPanelGeometry.windowSize(
            forContent: CGSize(width: 300, height: 200),
            metrics: metrics
        )
        #expect(size.width == 300)
        #expect(size.height == 200 + metrics.arrowHeight)
    }

    @Test func windowSizeClampsNegativeContent() {
        let size = MBKPanelGeometry.windowSize(
            forContent: CGSize(width: -10, height: -10),
            metrics: metrics
        )
        #expect(size.width == 0)
        #expect(size.height == metrics.arrowHeight)
    }

    // MARK: - Top-edge invariant

    @Test func topEdgeIsPinnedForEveryHeight() {
        let topY: CGFloat = 875
        for height in stride(from: CGFloat(50), through: 700, by: 50) {
            let layout = MBKPanelGeometry.layout(
                content: CGSize(width: 400, height: height),
                anchorX: 700,
                topY: topY,
                visibleFrame: visibleFrame,
                metrics: metrics
            )
            #expect(layout.frame.maxY == topY)
        }
    }

    // MARK: - Centring

    @Test func unclampedPanelIsCentredOnAnchor() {
        let layout = MBKPanelGeometry.layout(
            content: CGSize(width: 400, height: 300),
            anchorX: 700,
            topY: 875,
            visibleFrame: visibleFrame,
            metrics: metrics
        )
        #expect(layout.frame.midX == 700)
        #expect(layout.wasClamped == false)
        #expect(layout.arrowCenterX == 200)
    }

    // MARK: - Clamping

    @Test func clampsAtRightEdgeAndKeepsArrowOnAnchor() {
        let anchorX: CGFloat = 1250
        let layout = MBKPanelGeometry.layout(
            content: CGSize(width: 400, height: 300),
            anchorX: anchorX,
            topY: 875,
            visibleFrame: visibleFrame,
            metrics: metrics
        )
        #expect(layout.wasClamped)
        #expect(layout.frame.maxX == visibleFrame.maxX - metrics.screenMargin)
        // Arrow still points at the status item, in window-local coordinates.
        #expect(abs(layout.frame.minX + layout.arrowCenterX - anchorX) < 0.001)
    }

    /// Past the corner radius the arrow stops tracking rather than deforming the bubble.
    @Test func arrowStopsAtTheCornerWhenAnchorIsBeyondIt() {
        let layout = MBKPanelGeometry.layout(
            content: CGSize(width: 400, height: 300),
            anchorX: 1439,
            topY: 875,
            visibleFrame: visibleFrame,
            metrics: metrics
        )
        #expect(layout.wasClamped)
        #expect(layout.arrowCenterX == 400 - metrics.cornerRadius - metrics.arrowWidth / 2)
    }

    @Test func clampsAtLeftEdge() {
        let layout = MBKPanelGeometry.layout(
            content: CGSize(width: 400, height: 300),
            anchorX: 20,
            topY: 875,
            visibleFrame: visibleFrame,
            metrics: metrics
        )
        #expect(layout.wasClamped)
        #expect(layout.frame.minX == visibleFrame.minX + metrics.screenMargin)
    }

    @Test func arrowNeverEntersTheCornerRadius() {
        let lowerBound = metrics.cornerRadius + metrics.arrowWidth / 2
        for anchorX in stride(from: CGFloat(0), through: 1440, by: 20) {
            let layout = MBKPanelGeometry.layout(
                content: CGSize(width: 400, height: 300),
                anchorX: anchorX,
                topY: 875,
                visibleFrame: visibleFrame,
                metrics: metrics
            )
            #expect(layout.arrowCenterX >= lowerBound)
            #expect(layout.arrowCenterX <= layout.frame.width - lowerBound)
        }
    }

    @Test func panelWiderThanScreenIsCentred() {
        let layout = MBKPanelGeometry.layout(
            content: CGSize(width: 2000, height: 300),
            anchorX: 1200,
            topY: 875,
            visibleFrame: visibleFrame,
            metrics: metrics
        )
        #expect(layout.frame.midX == visibleFrame.midX)
        // Origin is -280, so the anchor at 1200 lands 1480pt into the window.
        #expect(layout.arrowCenterX == 1480)
    }

    // MARK: - Off-origin screens

    @Test func layoutRespectsNonZeroScreenOrigin() {
        let secondary = CGRect(x: -1920, y: 200, width: 1920, height: 1000)
        let layout = MBKPanelGeometry.layout(
            content: CGSize(width: 400, height: 300),
            anchorX: -1910,
            topY: 1200,
            visibleFrame: secondary,
            metrics: metrics
        )
        #expect(layout.frame.minX == secondary.minX + metrics.screenMargin)
        #expect(layout.frame.maxY == 1200)
    }

    // MARK: - Height cap

    @Test func maxContentHeightIsFractionOfVisibleFrameMinusArrow() {
        let cap = MBKPanelGeometry.maxContentHeight(
            visibleFrame: visibleFrame,
            fraction: 0.8,
            metrics: metrics
        )
        #expect(cap == 875 * 0.8 - metrics.arrowHeight)
    }

    @Test func maxContentHeightIsNeverNegative() {
        let cap = MBKPanelGeometry.maxContentHeight(
            visibleFrame: CGRect(x: 0, y: 0, width: 100, height: 4),
            fraction: 0.8,
            metrics: metrics
        )
        #expect(cap == 0)
    }

    // MARK: - Content clamping

    @Test func clampContentAppliesWidthAndHeightLimits() {
        let clamped = MBKPanelGeometry.clampContent(
            CGSize(width: 120, height: 5000),
            minWidth: 280,
            maxWidth: 900,
            maxHeight: 700
        )
        #expect(clamped.width == 280)
        #expect(clamped.height == 700)

        let wide = MBKPanelGeometry.clampContent(
            CGSize(width: 1200, height: 100),
            minWidth: 280,
            maxWidth: 900,
            maxHeight: 700
        )
        #expect(wide.width == 900)
        #expect(wide.height == 100)
    }

    @Test func clampContentSurvivesInvertedLimits() {
        let clamped = MBKPanelGeometry.clampContent(
            CGSize(width: 100, height: 100),
            minWidth: 500,
            maxWidth: 300,
            maxHeight: -50
        )
        #expect(clamped.width == 500)
        #expect(clamped.height == 0)
    }

    // MARK: - Width cap
    //
    // MenuBarKit caps width against the screen only; it deliberately has no
    // min/max width of its own — that range lives on the adopter's views.

    @Test func maxContentWidthInsetsBothScreenMargins() {
        let width = MBKPanelGeometry.maxContentWidth(visibleFrame: visibleFrame, metrics: metrics)
        #expect(width == 1440 - metrics.screenMargin * 2)
    }

    @Test func maxContentWidthIsNeverNegative() {
        let width = MBKPanelGeometry.maxContentWidth(
            visibleFrame: CGRect(x: 0, y: 0, width: 4, height: 100),
            metrics: metrics
        )
        #expect(width == 0)
    }

    // MARK: - Bubble shape

    @MainActor
    @Test func bubbleShapeSpansFullRectWithArrowAtTop() {
        let bounds = Self.bubbleBounds(arrowCenterX: 200)
        // Arrow tip touches the top edge; the body fills the rest of the rect.
        #expect(bounds.minY == 0)
        #expect(bounds.maxY == 300)
        #expect(bounds.width == 400)
    }

    @MainActor
    @Test func bubbleShapeKeepsArrowInsideCornersWhenAnchorIsOutOfRange() {
        let low = Self.bubbleBounds(arrowCenterX: -500)
        #expect(low.minX >= 0)
        #expect(low.maxX <= 400)

        let high = Self.bubbleBounds(arrowCenterX: 5000)
        #expect(high.minX >= 0)
        #expect(high.maxX <= 400)
    }

    @MainActor
    @Test func bubbleShapeWithoutArrowIsAPlainRoundedRect() {
        let bounds = Self.bubbleBounds(arrowCenterX: 200, arrowHeight: 0, arrowWidth: 0)
        #expect(bounds.minY == 0)
        #expect(bounds.maxY == 300)
    }

    // MARK: - Menu-bar detection

    @Test func menuBarIsVisibleWhenTheVisibleFrameIsShorterAtTheTop() {
        let full = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        #expect(!MBKPanelGeometry.isMenuBarHidden(screenFrame: full, visibleFrame: visible))
    }

    @Test func menuBarIsHiddenWhenTheVisibleFrameReachesTheScreenTop() {
        let full = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // Auto-hide: the Dock still takes the bottom, the top is fully free.
        let visible = CGRect(x: 0, y: 70, width: 1440, height: 830)
        #expect(MBKPanelGeometry.isMenuBarHidden(screenFrame: full, visibleFrame: visible))
    }

    @Test func menuBarDetectionIgnoresSubPointJitter() {
        let full = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // The 1pt oscillation that made the old status-window heuristic flap.
        #expect(MBKPanelGeometry.isMenuBarHidden(
            screenFrame: full,
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 899)
        ))
        #expect(MBKPanelGeometry.isMenuBarHidden(
            screenFrame: full,
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        ))
    }

    /// Bounding rect of `MBKBubbleShape` drawn into a fixed 400x300 rect.
    /// - Parameters:
    ///   - arrowCenterX: Arrow centre in points from the leading edge.
    ///   - arrowHeight: Arrow height; defaults to the standard metric.
    ///   - arrowWidth: Arrow base width; defaults to the standard metric.
    @MainActor
    private static func bubbleBounds(
        arrowCenterX: CGFloat,
        arrowHeight: CGFloat = MBKPanelMetrics.default.arrowHeight,
        arrowWidth: CGFloat = MBKPanelMetrics.default.arrowWidth
    ) -> CGRect {
        let shape = MBKBubbleShape(
            arrowCenterX: arrowCenterX,
            arrowHeight: arrowHeight,
            arrowWidth: arrowWidth,
            cornerRadius: MBKPanelMetrics.default.cornerRadius
        )
        return shape.path(in: CGRect(x: 0, y: 0, width: 400, height: 300)).boundingRect
    }
}
