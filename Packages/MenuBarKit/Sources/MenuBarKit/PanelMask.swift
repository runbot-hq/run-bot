// PanelMask.swift
// MenuBarKit
//
// Draws the bubble-with-arrow silhouette used as the `maskImage` of the
// panel's `NSVisualEffectView`.
//
// WHY WE DRAW THE ARROW OURSELVES:
// `NSPopover` owns its arrow as AppKit chrome and bakes the arrow offset at
// `show()` time. Every manual resize afterwards left the arrow clipped or
// detached (#2278/#2279, PR #2289). Here the arrow is just pixels in a mask we
// regenerate on every frame change, so it can never disagree with the window.
//
// Per the AppKit header, setting `maskImage` on the view that is the window's
// `contentView` also makes the window shadow follow the mask — so the shadow
// hugs the arrow for free. Do not try to fake the shadow another way.
//
// WHY CoreGraphics AND NOT `NSImage(size:flipped:drawingHandler:)`:
// That initialiser's drawing handler is a plain escaping closure with no actor
// isolation, so reaching for `NSGraphicsContext.current` or `NSBezierPath`
// inside it means touching main-actor-isolated AppKit from a nonisolated
// context under Swift 6. Rendering into a `CGContext` bitmap here has no such
// problem: `CGContext` and `CGPath` carry no isolation, and the only AppKit
// type left is the `NSImage` wrapper, built on the main actor by this function.
// ❌ NEVER port this back to a drawing handler.
import AppKit

/// Builder for the panel's bubble-with-arrow mask image.
enum MBKPanelMask {

    /// Renders the mask for one window size and arrow position.
    ///
    /// The bubble occupies the lower `size.height - metrics.arrowHeight` points
    /// and the arrow points up out of its top edge, centred on `arrowCenterX`.
    /// Coordinates are bottom-left origin, matching both `CGContext` and the
    /// window frame math in `MBKPanelGeometry`.
    ///
    /// The bubble and the arrow are filled as two separate paths that overlap by
    /// one point. Filling them as a single path would let the non-zero winding
    /// rule punch a seam where the triangle meets the rounded rectangle.
    ///
    /// - Parameters:
    ///   - size: Full window size in points, including the arrow strip.
    ///   - arrowCenterX: Arrow centre in window-local points.
    ///   - metrics: Chrome metrics.
    ///   - scale: Backing scale factor of the target display.
    /// - Returns: An opaque-black silhouette on a transparent background, sized in points.
    @MainActor
    static func image(
        size: CGSize,
        arrowCenterX: CGFloat,
        metrics: MBKPanelMetrics,
        scale: CGFloat
    ) -> NSImage {
        let pointSize = CGSize(width: max(size.width, 1), height: max(size.height, 1))
        let pixelScale = max(scale, 1)
        let pixelWidth = max(Int((pointSize.width * pixelScale).rounded()), 1)
        let pixelHeight = max(Int((pointSize.height * pixelScale).rounded()), 1)

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            // An empty image masks nothing away, which degrades to a square
            // panel rather than an invisible one.
            return NSImage(size: pointSize)
        }

        context.scaleBy(x: pixelScale, y: pixelScale)
        context.setFillColor(CGColor(gray: 0, alpha: 1))

        let bubbleHeight = max(pointSize.height - metrics.arrowHeight, 0)
        let bubbleRect = CGRect(x: 0, y: 0, width: pointSize.width, height: bubbleHeight)
        let radius = min(metrics.cornerRadius, min(bubbleRect.width, bubbleRect.height) / 2)
        context.addPath(CGPath(
            roundedRect: bubbleRect,
            cornerWidth: max(radius, 0),
            cornerHeight: max(radius, 0),
            transform: nil
        ))
        context.fillPath()

        let arrowHalf = metrics.arrowWidth / 2
        if metrics.arrowHeight > 0, arrowHalf > 0 {
            // Overlap the bubble by 1pt so no hairline seam survives antialiasing.
            let base = max(bubbleHeight - 1, 0)
            let arrow = CGMutablePath()
            arrow.move(to: CGPoint(x: arrowCenterX - arrowHalf, y: base))
            arrow.addLine(to: CGPoint(x: arrowCenterX, y: pointSize.height))
            arrow.addLine(to: CGPoint(x: arrowCenterX + arrowHalf, y: base))
            arrow.closeSubpath()
            context.addPath(arrow)
            context.fillPath()
        }

        guard let cgImage = context.makeImage() else { return NSImage(size: pointSize) }
        return NSImage(cgImage: cgImage, size: pointSize)
    }
}
