// SheetView.swift
// MenuBarKitExample

import MenuBarKit
import SwiftUI

struct SheetView: View {
    @Environment(AppState.self) private var appState
    @Environment(MBKOverlayGate.self) private var overlayGate

    var body: some View {
        #if DEBUG
        let _ = print("[SheetView] body evaluated — showSheetAlert=\(appState.showSheetAlert) gate=\(overlayGate.hasActiveOverlay)")
        #endif
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 12) {
            Text("Sheet").font(.headline).frame(maxWidth: .infinity, alignment: .center)
            Divider()

            // Scenario: file picker launched from inside a sheet
            GroupBox("Pick folder from sheet") {
                Button("Pick folder") {
                    #if DEBUG
                    print("[SheetView] Pick folder tapped — gate=\(overlayGate.hasActiveOverlay) isSheetPresented=\(appState.isSheetPresented)")
                    #endif
                    mbkOpenFilePicker(overlayGate: overlayGate) { url in
                        #if DEBUG
                        print("[SheetView] mbkOpenFilePicker completion — url=\(String(describing: url)) gate=\(overlayGate.hasActiveOverlay) isSheetPresented=\(appState.isSheetPresented)")
                        #endif
                        appState.sheetPickedURL = url
                    }
                }
                if let path = appState.sheetPickedURL?.path {
                    Text(path)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                }
                Text("Picker opens. Sheet + popover stay alive after dismiss.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            GroupBox("Alert from sheet") {
                Button("Show error alert") {
                    #if DEBUG
                    print("[SheetView] Show error alert tapped")
                    #endif
                    appState.showSheetAlert = true
                }
                Text("Alert should appear. Sheet + popover stay alive.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .mbkAlert("Simulated Error", isPresented: $appState.showSheetAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("This is a test error message.")
            }

            Divider()

            // WHY appState.isSheetPresented = false INSTEAD OF @Environment(\.dismiss):
            //   This sheet is driven by .mbkSheet(isPresented: $appState.isSheetPresented).
            //   Writing the same binding that controls presentation is the correct and
            //   intentional dismiss idiom here — it keeps the AppDelegate snapshot
            //   lifecycle coherent. AppDelegate's onWillClose reads isSheetPresented to
            //   decide whether to force-close; onDidShow writes it to respawn the sheet.
            //   If we used @Environment(\.dismiss) instead, SwiftUI would nil the binding
            //   internally on the same turn — functionally identical — but the explicit
            //   write makes the data flow visible and keeps the pattern consistent with
            //   how AppDelegate drives presentation from outside the view hierarchy.
            //   Do not replace this with @Environment(\.dismiss) — it would work but
            //   would obscure the intentional coupling between SheetView and AppState.
            Button("Close") {
                #if DEBUG
                print("[SheetView] Close tapped — setting isSheetPresented=false")
                #endif
                appState.isSheetPresented = false
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(16)
        .fixedSize()
        .onAppear {
            #if DEBUG
            print("[SheetView] onAppear  gate=\(overlayGate.hasActiveOverlay) isSheetPresented=\(appState.isSheetPresented)")
            #endif
        }
        .onDisappear {
            #if DEBUG
            print("[SheetView] onDisappear gate=\(overlayGate.hasActiveOverlay) isSheetPresented=\(appState.isSheetPresented)")
            #endif
        }
    }
}
