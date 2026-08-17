// MigrationSettingsSectionLayout.swift
// RunBot

import SwiftUI

// MARK: - MigrationSettingsSectionLayout

/// Titled section wrapper for migration settings detail views.
///
/// Renders a `.title2.weight(.semibold)` title followed by a `VStack` of
/// section content with 28-point spacing.
///
/// ## Usage
/// ```swift
/// MigrationSettingsSectionLayout(title: "Authentication") {
///     authCard
/// }
/// ```
struct MigrationSettingsSectionLayout<Content: View>: View {

    // MARK: - Inputs

    /// The section heading displayed above the content.
    let title: String

    /// The section body, typically one or more card views.
    let content: Content

    // MARK: - Init

    /// Creates a section layout with the given title and content builder.
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    // MARK: - Body

    /// Section title followed by card content.
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text(title)
                .font(.title2.weight(.semibold))

            content
        }
    }
}
