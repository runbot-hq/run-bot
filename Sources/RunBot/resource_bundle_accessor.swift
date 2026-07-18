// resource_bundle_accessor.swift
// RunBot
//
// Custom override of SwiftPM's auto-generated resource bundle accessor.
//
// WHY THIS FILE EXISTS:
// SwiftPM generates resource_bundle_accessor.swift using:
//   Bundle.main.bundleURL.appendingPathComponent("RunBot_RunBot.bundle")
// Inside a .app, Bundle.main.bundleURL == RunBot.app/ (the app root).
// codesign rejects any directory at the app root other than Contents/,
// so the bundle cannot live at RunBot.app/RunBot_RunBot.bundle.
//
// FILENAME IS INTENTIONAL:
// This file is named resource_bundle_accessor.swift so SwiftPM skips
// generating its own version. Do NOT rename this file. Do NOT delete
// this file. See issue #2136.
//
// LOOKUP PATH (packaged .app):
//   RunBot.app/Contents/MacOS/RunBot  (executable)
//     → deletingLastPathComponent()   → Contents/MacOS/
//     → deletingLastPathComponent()   → Contents/
//     → appending "Resources"         → Contents/Resources/
//     → appending bundle name         → Contents/Resources/RunBot_RunBot.bundle
//
// LOOKUP PATH (swift run / .build):
//   .build/arm64-apple-macosx/release/RunBot
//     → deletingLastPathComponent()   → release/
//     → appending bundle name         → release/RunBot_RunBot.bundle
//
// build.sh places the bundle at Contents/Resources/ — codesign accepts
// any content inside Contents/. The bundle is correctly signed via
// codesign --deep. See build.sh for placement details.

import Foundation

extension Foundation.Bundle {
    /// The resource bundle for the RunBot module.
    ///
    /// SwiftPM's auto-generated resource_bundle_accessor.swift resolves
    /// Bundle.module via Bundle.main.bundleURL, which inside a .app points
    /// to RunBot.app/ (the app root). codesign rejects any directory at the
    /// app root other than Contents/, so the bundle cannot live there.
    ///
    /// This override locates the bundle relative to the running executable,
    /// which is always at Contents/MacOS/ inside a packaged .app.
    ///
    /// Do NOT replace this with Bundle.main.bundleURL.appending... — that
    /// resolves to the app root, not Contents/Resources/. See issue #2136.
    static nonisolated let module: Bundle = {
        let executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            .resolvingSymlinksInPath()

        // Packaged .app: executable is at Contents/MacOS/RunBot
        // Walk up two levels to Contents/, then into Resources/
        let bundleURL = executableURL
            .deletingLastPathComponent()          // → Contents/MacOS/
            .deletingLastPathComponent()          // → Contents/
            .appendingPathComponent("Resources")  // → Contents/Resources/
            .appendingPathComponent("RunBot_RunBot.bundle")

        // Development fallback: swift run or direct .build/ binary execution.
        // SwiftPM places the bundle next to the executable in .build/.
        let devBundleURL = executableURL
            .deletingLastPathComponent()
            .appendingPathComponent("RunBot_RunBot.bundle")

        guard let bundle = Bundle(url: bundleURL) ?? Bundle(url: devBundleURL) else {
            Swift.fatalError(
                "could not load resource bundle: from \(bundleURL.path) or \(devBundleURL.path)"
            )
        }
        return bundle
    }()
}
