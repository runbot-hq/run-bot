// RootView.swift
// MenuBarKitExample

import MenuBarKit
import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        #if DEBUG
        let _ = print("[RootView] body evaluated — route=\(appState.route) isSheetPresented=\(appState.isSheetPresented)")
        #endif
        Group {
            switch appState.route {
            case .main:     MainView()
            case .settings: SettingsView()
            }
        }
        .id(appState.route)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        #if DEBUG
                        print("[RootView] GeometryReader onAppear size=(\(geo.size.width),\(geo.size.height)) route=\(appState.route)")
                        #endif
                    }
                    .onChange(of: geo.size) { old, new in
                        #if DEBUG
                        print("[RootView] size changed (\(old.width),\(old.height)) -> (\(new.width),\(new.height)) route=\(appState.route)")
                        #endif
                    }
            }
        )
        .onAppear {
            #if DEBUG
            print("[RootView] onAppear  route=\(appState.route) isSheetPresented=\(appState.isSheetPresented)")
            #endif
        }
        .onDisappear {
            #if DEBUG
            print("[RootView] onDisappear route=\(appState.route) isSheetPresented=\(appState.isSheetPresented)")
            #endif
        }
    }
}
