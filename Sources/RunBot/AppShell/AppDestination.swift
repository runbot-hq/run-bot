// AppDestination.swift
// RunBot

import SwiftUI

/// Top-level sidebar route model.
/// Raw string value prepares for `@SceneStorage` persistence in a later step.
enum AppDestination: String, CaseIterable, Identifiable {
    /// The workflows feature destination.
    case workflows
    /// The local runners feature destination.
    case localRunners
    /// The scopes feature destination.
    case scopes
    /// The settings feature destination.
    case settings

    /// Stable identity for `List` and `NavigationSplitView` selection.
    var id: Self { self }

    /// Display title for the sidebar row.
    var title: String {
        switch self {
        case .workflows: "Workflows"
        case .localRunners: "Local runners"
        case .scopes: "Scopes"
        case .settings: "Settings"
        }
    }

    /// SF Symbol name for the sidebar row icon.
    var systemImage: String {
        switch self {
        case .workflows: "bolt.horizontal.circle"
        case .localRunners: "desktopcomputer"
        case .scopes: "scope"
        case .settings: "gearshape"
        }
    }
}
