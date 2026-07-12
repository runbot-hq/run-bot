// Logging.swift
// MenuBarKit

import Foundation

/// Debug-only logging for MenuBarKit internals.
/// Compiled out entirely in release builds — @inlinable ensures the call site
/// itself is a zero-cost no-op with no function call overhead.
@inlinable
public func mbkLog(_ subsystem: String, _ message: String) {
#if DEBUG
    print("[MBK:\(subsystem)] \(message)")
#endif
}
