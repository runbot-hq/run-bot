// Logging.swift
// MenuBarKit
//
// Lightweight tagged logger for spike-stage debugging.
//
// WHY print() AND NOT os.Logger:
//   os_log output does not appear in the Xcode/swift run console during
//   development without a custom subsystem + Console.app filter. print() is
//   immediately visible and keeps the spike friction-free.
//
// #if DEBUG GUARD:
//   mbkLog is a no-op in release builds. MenuBarKit is a .library product —
//   any consumer linking it would otherwise get these prints in production.
//   Before MenuBarKit ships as a real package, replace with os.Logger using
//   the same [MBK][<tag>] format so the grep-friendly structure is preserved.

/// Emits a tagged log line in debug builds. No-op in release.
@inlinable
public func mbkLog(_ tag: String, _ message: String) {
    #if DEBUG
    print("[MBK][\(tag)] \(message)")
    #endif
}
