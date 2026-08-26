// main.swift
// RunBot
/// Entry point for the SwiftUI windowed application.
/// `RunBotApp.main()` is called explicitly because `@main` cannot
/// coexist with top-level code in `main.swift`.
/// ❌ NEVER remove the MainActor.assumeIsolated wrapper — the OS always
/// starts on the main thread and this satisfies strict-concurrency checking.
import SwiftUI

// RunBot requires Apple Silicon. Building for x86_64 is not supported.
#if !arch(arm64)
#error("RunBot requires Apple Silicon (arm64). x86_64 is not supported.")
#endif

MainActor.assumeIsolated {
    RunBotApp.main()
}
