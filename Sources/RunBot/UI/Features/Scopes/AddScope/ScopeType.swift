// ScopeType.swift
// RunBot

// MARK: - ScopeType

/// Enumerates the two scopes at which a GitHub Actions runner (or scope) can be registered.
///
/// Shared by `AddRunnerSheet` and `AddScopeSheet`. Previously each file defined its own
/// local copy of this enum — extracted here to eliminate duplication (F-45 / #1644).
///
/// ## Case order
/// `repo` is listed first so that segmented pickers built with `ForEach(ScopeType.allCases)`
/// display **Repository | Organisation** — matching the `AddRunnerSheet` default and the
/// most-common use case.
enum ScopeType: String, CaseIterable, Identifiable {
    /// Runner registered to a single repository.
    case repo = "Repository"
    /// Runner registered at organisation level.
    case org = "Organisation"
    /// Stable identity backed by `rawValue`.
    var id: String { rawValue }
}
