// Logger.swift
// RunBotCore
import Foundation
import os

// MARK: - Unified logging
//
// log() is the single call-site throughout the app.
// Backed by os.Logger so messages appear in Console.app with
// subsystem/category filtering and are zero-cost in release builds
// (.debug level is compiled out by the OS when not actively streaming).

// MARK: - Log categories

/// Logical subsystem categories for `os.Logger` filtering in Console.app
/// and `log stream --predicate`.
///
/// **Access level:** `public` because the app target (`Sources/RunBot/**`)
/// calls `log()` directly from `AppDelegate`, views, and sheets.
/// `internal` would cause a compile error in the app target.
///
/// **Raw value convention:** all raw values are lowercase kebab-case so
/// Console.app category predicates are visually consistent.
/// Example: `category == "poll-bridge"` not `category == "pollBridge"`.
public enum LogCategory: String, CaseIterable {
    /// Fallback / uncategorised (migration default).
    case general
    /// GitHub transport, auth and API layers.
    case transport
    /// Runner polling, stores, services and models.
    case runner
    /// Scope store and preferences.
    case scope
    /// OS-level services: Keychain, LoginItem, ProcessRunner,
    /// TerminalLauncher, LogFetcher.
    case services
    /// Panel / MBK sizing, layout, and navigation diagnostics.
    /// Temporary — remove after side-jump bug is resolved.
    case panel
}

// MARK: - Logger instances

/// The OSLog subsystem identifier for the app, shared across all log categories.
private let subsystem = "com.eoncode.run-bot"

/// One `os.Logger` per `LogCategory`, created once at launch.
///
/// Built from `LogCategory.allCases` via `uniqueKeysWithValues`, so the dictionary
/// is guaranteed to contain every current case. `resolvedLogger(for:)` depends on this
/// invariant — if a new case is added without a corresponding entry in this dictionary,
/// `resolvedLogger` will call `preconditionFailure`, surfacing the omission in debug
/// and test builds without risking a production crash for a structurally unreachable path.
///
/// **Why `nonisolated(unsafe)`?**
/// Swift 6 strict-concurrency mode requires all mutable global state to be either
/// actor-isolated or explicitly marked `nonisolated(unsafe)`. Even though
/// `[LogCategory: Logger]` is technically `Sendable` (both `LogCategory` and
/// `os.Logger` are value/struct types with no mutable state), the Swift 6 checker
/// emits a `#MutableGlobalVariable` diagnostic for any mutable global `let` or `var`
/// whose type does not carry a *public* unconditional `Sendable` conformance visible
/// at the use site — and the `os` module's `Logger` type does not declare such a
/// conformance in all SDK versions targeted by this project. `nonisolated(unsafe)`
/// is the correct suppression: it asserts to the compiler that we, the authors,
/// guarantee safe concurrent access — which is true because this dictionary is
/// initialised once at module load and never mutated thereafter.
nonisolated(unsafe) private let loggers: [LogCategory: Logger] = Dictionary(
    uniqueKeysWithValues: LogCategory.allCases.map { category in
        (category, Logger(subsystem: subsystem, category: category.rawValue))
    }
)

/// Returns the `os.Logger` for the given category.
private func resolvedLogger(for category: LogCategory) -> Logger {
    guard let logger = loggers[category] else {
        preconditionFailure("Logger for category '\(category.rawValue)' not found — add a matching case to LogCategory")
    }
    return logger
}

// MARK: - Public log() entry-point

/// Writes a debug-level message to the unified logging system.
///
/// **Access level:** `public` — consumed by the app target (`Sources/RunBot/**`)
/// in addition to `RunBotCore`. Do not narrow to `internal`.
///
/// Messages are visible in:
///   - Console.app (filter by subsystem: com.eoncode.run-bot, then by category)
///   - `log stream --level debug --predicate 'subsystem == "com.eoncode.run-bot"'`
///   - Xcode debug console when running from Xcode
///
/// In release builds the OS elides .debug calls at zero cost.
///
/// **`privacy: .public` policy**
/// All three interpolated fields (filename, line, message) are marked `.public`.
/// This is a deliberate, app-wide policy: RunBot is a developer tool whose
/// operator controls the machine and reads their own logs. The OS default
/// (`.private`) would redact every dynamic string in Console.app and `log stream`,
/// making diagnostic output useless in the field. `.public` opts the entire
/// message out of OS-level redaction.
///
/// - Parameters:
///   - message:  Human-readable log message.
///   - category: Subsystem category for Console.app filtering.
///               Defaults to `.general` so existing call sites compile unchanged.
public func log(
    _ message: String,
    category: LogCategory = .general,
    file: String = #file,
    line: Int = #line
) {
    let filename = URL(fileURLWithPath: file)
        .deletingPathExtension().lastPathComponent
    resolvedLogger(for: category).debug(
        "\(filename, privacy: .public):\(line, privacy: .public) — \(message, privacy: .public)"
    )
}
