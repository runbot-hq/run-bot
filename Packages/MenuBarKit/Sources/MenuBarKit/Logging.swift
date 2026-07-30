// Logging.swift
// MenuBarKit

import Foundation

/// The active log handler. Defaults to `print` in debug builds, no-op in release.
/// Replace to route MBK logs to your own logger (os_log, structured logger, etc.).
/// Set this before calling `MBKPanelController.setup()`.
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
#if DEBUG
    print("[MBK:\(subsystem)] \(message)")
#endif
}

/// Logging entry point for MBK and its consumers. Routes through `mbkLogHandler`.
/// The default handler is a no-op in release builds unless overridden by the host app
/// (e.g. to route to os_log). Call sites are always compiled in — override
/// `mbkLogHandler` before `setup()` to capture logs in release.
@MainActor
public func mbkLog(_ subsystem: String, _ message: String) {
    mbkLogHandler(subsystem, message)
}
