// StatusBarSheetSpike.swift
// StatusBarSheetSpike -- spike/statusbar-sheet-swiftui branch
//
// Exact reproduction of the pattern claimed to work in:
// https://stackoverflow.com/a/78843009
//
// Rules:
//   1. Use @Binding to dismiss -- NOT @Environment(\.dismiss)
//      (@Environment(\.dismiss) closes the entire MenuBarExtra window)
//   2. Sheet content is a SEPARATE view struct, not an inline closure
//   3. .sheet is attached to the outermost view, not a nested child
//
// HOW TO RUN:
//   swift run StatusBarSheetSpike
//
// REQUIREMENTS: macOS 13+, Swift 6
// DEPENDENCIES: none

import SwiftUI

@main
struct StatusBarSheetApp: App {
    var body: some Scene {
        MenuBarExtra("Spike", systemImage: "flask.fill") {
            ContentView()
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    @State private var sheetDisplayed: Bool = false

    var body: some View {
        VStack {
            Text("Menu Bar Window")
                .padding()
            Button("Present Sheet") {
                sheetDisplayed = true
            }
            .padding()
            .frame(minWidth: 300, minHeight: 200)
        }
        // Rule 3: .sheet on the outermost VStack
        .sheet(isPresented: $sheetDisplayed) {
            // Rule 2: separate struct, not inline content
            SheetContentView(sheetDisplayed: $sheetDisplayed)
        }
    }
}

// Rule 2: sheet content in its own struct
struct SheetContentView: View {
    @Binding var sheetDisplayed: Bool

    var body: some View {
        VStack {
            Text("Sheet")
            // Rule 1: set binding directly, NOT dismiss()
            Button("Close Sheet") {
                sheetDisplayed = false
            }
        }
        .frame(minWidth: 200, minHeight: 200)
    }
}
