// Logging.swift
// MenuBarKit

import Foundation

/// The active log handler. Defaults to `print`. Replace to route MBK logs
/// to your own logger (os_log, structured logger, etc.).
/// Set this before calling `MBKPopoverController.setup()`.
/// Isolated to `@MainActor` because all MBK log call sites are on the main actor.
///
/// - Note: `deinit` log lines in `MBKSheetAnchorTask` bypass this handler and
///   always go to `print` directly. Swift does not allow calling `@MainActor`-
///   isolated functions from `deinit`, so `mbkLog` (and therefore this handler)
///   cannot be reached from that context. If you install a custom handler to
///   route logs to os_log or a structured logger, be aware that object
///   deallocation traces from `MBKSheetAnchorTask` will still appear on stdout
///   regardless of your handler configuration.
///
/// Example:
/// ```swift
/// mbkLogHandler = { subsystem, message in
///     logger.debug("[MBK:\(subsystem)] \(message)")
/// }
/// ```
@MainActor
public var mbkLogHandler: (_ subsystem: String, _ message: String) -> Void = { subsystem, message in
    print("[MBK:\(subsystem)] \(message)")
}

/// Internal logging entry point. Routes through `mbkLogHandler`.
/// Compiled out entirely in release builds.
@MainActor
@inlinable
func mbkLog(_ subsystem: String, _ message: String) {
#if DEBUG
    mbkLogHandler(subsystem, message)
#endif
}
