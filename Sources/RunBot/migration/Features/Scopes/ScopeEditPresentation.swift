// ScopeEditPresentation.swift
// RunBot

import RunBotCore

// MARK: - ScopeEditPresentation

/// Identifiable container for the scope-edit sheet's required inputs.
///
/// Consolidates `ScopeEntry` and its `ScopePreferences` into a single
/// presentation value so `.sheet(item:)` can gate on one atomic state
/// and prevent mismatched scope/preference pairs on rapid double-taps.
struct ScopeEditPresentation: Identifiable {
    /// The scope entry to edit.
    let entry: ScopeEntry
    /// Preferences snapshot fetched before the sheet appears.
    let preferences: ScopePreferences

    /// Stable identity backed by the scope entry.
    var id: ScopeEntry.ID { entry.id }
}
