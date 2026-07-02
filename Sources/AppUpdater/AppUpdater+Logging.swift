// AppUpdater+Logging.swift
// AppUpdater
import Foundation
import os

// MARK: - Unified logging (module-local)

/// Single `os.Logger` shared by every `AppUpdater` source file.
///
/// The library is standalone and must not depend on `RunBotCore`'s `log()`
/// helper, so it carries its own logger. The subsystem is a fixed string
/// rather than `Bundle.module.bundleIdentifier` because `AppUpdater` ships no
/// resources — `Bundle.module` is not synthesised for a resource-free target,
/// so referencing it would fail to compile.
///
/// Messages appear in Console.app under subsystem `io.github.appupdater`,
/// category `AppUpdater`. `.debug` calls are elided at zero cost in release
/// builds by the OS when no one is streaming.
///
/// `os.Logger` is a value type with no mutable state; a top-level `let` is
/// safe under Swift 6 strict concurrency without `nonisolated(unsafe)` because
/// it is never mutated after initialisation.
let appUpdaterLogger = Logger(
    subsystem: "io.github.appupdater",
    category: "AppUpdater"
)
