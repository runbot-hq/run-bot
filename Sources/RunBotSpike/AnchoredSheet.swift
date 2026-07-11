// AnchoredSheet.swift
// RunBotSpike - spike/swiftui-nav-sheet
//
// SwiftUI .sheet() creates a borderless NSWindow that is NOT automatically
// a child of the popover window. Without addChildWindow it floats
// independently and hides when the app loses focus.
//
// This modifier walks NSApp.windows after the sheet appears to find the new
// borderless window and calls addChildWindow(_:ordered:) on the popover window.
//
// overlayCount is gone — dismiss blocking is now handled in popoverShouldClose
// by inspecting the window hierarchy directly (see AppDelegate.swift).

import AppKit
import SwiftUI

extension View {
    func anchoredSheet<SheetContent: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        modifier(NavAnchoredSheetModifier(
            isPresented: isPresented,
            sheetContent: content
        ))
    }
}

struct NavAnchoredSheetModifier<SheetContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let sheetContent: () -> SheetContent

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, content: sheetContent)
            .onChange(of: isPresented) { _, newValue in
                if newValue {
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
