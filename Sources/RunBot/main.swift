// main.swift
// RunBot
/// Entry point — launches the new SwiftUI windowed app shell.
/// Migration step 1 (#2797/#2799): RunBotDesktopApp replaces the AppDelegate
/// run loop. @main cannot coexist with main.swift top-level code, so
/// RunBotDesktopApp.main() is called explicitly here instead.
/// ❌ NEVER remove the MainActor.assumeIsolated wrapper — the OS always
/// starts on the main thread and this satisfies strict-concurrency checking.
import SwiftUI

// RunBot requires Apple Silicon. Building for x86_64 is not supported.
#if !arch(arm64)
#error("RunBot requires Apple Silicon (arm64). x86_64 is not supported.")
#endif

MainActor.assumeIsolated {
    RunBotDesktopApp.main()
}
