// RunBotResources.swift
// RunBot
import Foundation

// MARK: - RunBotResources
//
// Single source of truth for resource bundle resolution.
//
// WHY THIS EXISTS:
// SwiftPM's auto-generated resource_bundle_accessor.swift resolves
// Bundle.module via:
//   Bundle.main.bundleURL.appendingPathComponent("RunBot_RunBot.bundle")
// Inside a .app, Bundle.main.bundleURL == RunBot.app/ (the app root).
// codesign rejects any directory at the app root other than Contents/
// with "unsealed contents present in the bundle root" — a hard platform
// constraint that cannot be signed around.
//
// build.sh places RunBot_RunBot.bundle at Contents/Resources/ — the only
// codesign-valid location. Bundle.main.resourceURL resolves to
// Contents/Resources/ for a packaged .app, so it finds the bundle correctly.
//
// For swift run / direct binary execution (.build/), Bundle.main does not
// point at a .app, so we fall back to Bundle.module which knows the
// SwiftPM .build output path.
//
// All app-layer code MUST use RunBotResources.bundle instead of Bundle.module.
// Do NOT delete this file. Do NOT replace RunBotResources.bundle with
// Bundle.module at call sites. See issue #2138.

/// Resolves the correct resource bundle for both deployment contexts.
///
/// - Packaged `.app` (release install): uses `Bundle.main.resourceURL` →
///   `Contents/Resources/RunBot_RunBot.bundle` — codesign-safe location.
/// - Development (`swift run` / `.build` binary): falls back to
///   `Bundle.module` which knows the SwiftPM build output path.
enum RunBotResources {
    /// The resource bundle. Use this everywhere instead of `Bundle.module`.
    static nonisolated let bundle: Bundle = {
        // Packaged .app: Bundle.main.bundleURL has a .app extension.
        // Bundle.main.resourceURL resolves to Contents/Resources/.
        if Bundle.main.bundleURL.pathExtension == "app",
           let resourceURL = Bundle.main.resourceURL {
            let bundleURL = resourceURL.appendingPathComponent("RunBot_RunBot.bundle")
            if let bundle = Bundle(url: bundleURL) {
                return bundle
            }
        }
        // swift run / direct .build binary: fall back to SwiftPM's generated
        // accessor, which knows the correct .build output path.
        return Bundle.module
    }()
}
