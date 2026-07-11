// AnchoredSheet.swift
// RunBotSpike - spike/swiftui-nav-sheet
//
// SwiftUI .sheet() creates a borderless NSWindow that is NOT automatically
// a child of the MenuBarExtra / popover window. Without addChildWindow it
// floats independently and can be hidden behind other windows or lose focus.
//
// AnchoredSheet walks NSApp.windows after the sheet appears to find the new
// borderless window and calls addChildWindow(_:ordered:) on the host window.
// overlayCount is managed here so the dismiss guard fires correctly.

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
                log("AnchoredSheet", "isPresented -> \(newValue)")
                if newValue {
                    overlayCount += 1
                    log("AnchoredSheet", "overlayCount=\(overlayCount), scheduling anchorSheetWindow")
                    Task { @MainActor in anchorSheetWindow() }
                }
            }
    }

    @MainActor
    private func anchorSheetWindow() {
        guard let hostWindow = NSApp.windows.first(where: {
            $0.styleMask.contains(.nonactivatingPanel)
        }) else {
            log("AnchoredSheet", "anchorSheetWindow: no nonactivatingPanel window found")
            return
        }
        log("AnchoredSheet", "hostWindow=\(NSStringFromClass(type(of: hostWindow)))")
        DispatchQueue.main.async {
            if let sheetWindow = NSApp.windows.first(where: {
                $0 !== hostWindow
                    && $0.styleMask.contains(.borderless)
                    && $0.isKeyWindow
            }) {
                log("AnchoredSheet", "addChildWindow class=\(NSStringFromClass(type(of: sheetWindow)))")
                hostWindow.addChildWindow(sheetWindow, ordered: .above)
            } else {
                log("AnchoredSheet", "anchorSheetWindow: no borderless+key window found")
            }
        }
    }
}
