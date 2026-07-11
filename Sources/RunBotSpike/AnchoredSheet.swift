// AnchoredSheet.swift
// RunBotSpike - spike/swiftui-nav-sheet
//
// SwiftUI .sheet() creates a borderless NSWindow that is NOT automatically
// a child of the popover window. Without addChildWindow it floats
// independently and hides when the app loses focus.
//
// This modifier:
//  1. Increments overlayCount so popoverShouldClose blocks outside-click
//     dismiss while the sheet is open.
//  2. After the sheet appears, walks NSApp.windows to find the new borderless
//     window and calls addChildWindow(_:ordered:) on the popover window.
//  3. Decrements overlayCount on dismiss.

import AppKit
import SwiftUI

extension View {
    func anchoredSheet<SheetContent: View>(
        isPresented: Binding<Bool>,
        overlayCount: Binding<Int>,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        modifier(NavAnchoredSheetModifier(
            isPresented: isPresented,
            overlayCount: overlayCount,
            sheetContent: content
        ))
    }
}

struct NavAnchoredSheetModifier<SheetContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var overlayCount: Int
    let sheetContent: () -> SheetContent

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, onDismiss: {
                overlayCount = max(0, overlayCount - 1)
                log("AnchoredSheet", "onDismiss overlayCount=\(overlayCount)")
            }, content: sheetContent)
            .onChange(of: isPresented) { _, newValue in
                if newValue {
                    overlayCount += 1
                    Task { @MainActor in anchorSheetWindow() }
                }
            }
    }

    @MainActor
    private func anchorSheetWindow() {
        guard let popoverWindow = NSApp.windows.first(where: {
            $0.styleMask.contains(.nonactivatingPanel)
        }) else {
            log("AnchoredSheet", "no nonactivatingPanel window found")
            return
        }
        DispatchQueue.main.async {
            if let sheetWindow = NSApp.windows.first(where: {
                $0 !== popoverWindow
                    && $0.styleMask.contains(.borderless)
                    && $0.isKeyWindow
            }) {
                log("AnchoredSheet", "addChildWindow")
                popoverWindow.addChildWindow(sheetWindow, ordered: .above)
            } else {
                log("AnchoredSheet", "no borderless+key window found")
            }
        }
    }
}
