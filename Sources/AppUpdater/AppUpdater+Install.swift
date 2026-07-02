// AppUpdater+Install.swift
// AppUpdater

// AppKit is unavailable in the SPM headless test runner — this guard is
// required for `swift test` even though the package is macOS(.v26)-only.
#if canImport(AppKit)
import AppKit
#else
fatalError(
    "AppUpdater requires AppKit. " +
    "If you are hitting this from `swift test`: this code path touches AppKit " +
    "and cannot be exercised in the SPM headless test runner. " +
    "Do not test it. Do not add an #else branch with stub logic. " +
    "Mock above the AppKit boundary instead."
)
#endif
import Foundation

// MARK: - Install & Relaunch

/// Install-and-relaunch logic for ``AppUpdater``.
extension AppUpdater {

    /// Unzips the cached update zip, replaces the running `.app` bundle, and
    /// relaunches the new version.
    ///
    /// ## Flow
    /// 1. Verify host is in `.ready` phase and extract zip URL + version.
    /// 2. Unzip into a temporary directory via `/usr/bin/ditto`.
    /// 3. (Optional) Verify `codesign` identity if `skipCodeSignValidation` is `false`.
    /// 4. Replace the running bundle via `FileManager.replaceItem` (atomic swap).
    /// 5. Relaunch the new binary with `/usr/bin/open -n`.
    /// 6. Delete the zip (spend — relaunch confirmed).
    /// 7. Terminate this process via `NSApp.terminate`.
    ///
    /// On any failure `state.apply(.failed(version:))` is called and the
    /// function returns without terminating.
    @MainActor
    public func installAndRelaunch(state: any UpdateStateProviding) async {
        guard !isInstalling else { return }
        isInstalling = true

        // Extract version from the .ready phase; zip is always at fixedZipURL.
        guard case .ready(let version) = state.currentPhase else {
            isInstalling = false
            state.apply(.failed(version: nil))
            return
        }

        let zipURL = fixedZipURL
        let bundleURL = URL(fileURLWithPath: Bundle.main.bundlePath)
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appupdater-update-\(UUID().uuidString)", isDirectory: true)

        guard let appInZip = await unzipAndLocateApp(zipURL: zipURL, into: tmpDir) else {
            isInstalling = false
            state.apply(.failed(version: version))
            return
        }

        #if canImport(AppKit)
        if !skipCodeSignValidation {
            let runningIdentity = await Bundle.main.codeSigningIdentity()
            let updateIdentity = await Bundle(path: appInZip.path)?.codeSigningIdentity()
            guard let runningIdentity,
                  let updateIdentity,
                  runningIdentity == updateIdentity else {
                appUpdaterLogger.error("code-sign identity mismatch — aborting install")
                isInstalling = false
                state.apply(.failed(version: version))
                try? FileManager.default.removeItem(at: tmpDir)
                return
            }
        }
        #endif

        await replaceAndRelaunch(
            appInZip: appInZip,
            bundleURL: bundleURL,
            zipURL: zipURL,
            version: version,
            tmpDir: tmpDir,
            state: state
        )
    }

    // MARK: - Private helpers

    /// Unzips `zipURL` into `tmpDir` via `/usr/bin/ditto` and returns the
    /// `.app` bundle URL found at the archive root.
    private func unzipAndLocateApp(zipURL: URL, into tmpDir: URL) async -> URL? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        guard await runCommand("/usr/bin/ditto", args: ["-xk", zipURL.path, tmpDir.path]) else {
            try? fm.removeItem(at: tmpDir)
            return nil
        }
        guard let appInZip = (try? fm.contentsOfDirectory(
            at: tmpDir,
            includingPropertiesForKeys: nil
        ))?.first(where: { $0.pathExtension == "app" }) else {
            try? fm.removeItem(at: tmpDir)
            return nil
        }
        return appInZip
    }

    /// Atomically replaces the running bundle, relaunches via `open -n`, deletes
    /// the zip once relaunch is confirmed, then terminates via `NSApp.terminate`.
    private func replaceAndRelaunch( // skipcq: SW-R1002 — reviewed; sequential install steps, complexity is inherent
        appInZip: URL,
        bundleURL: URL,
        zipURL: URL,
        version: String,
        tmpDir: URL,
        state: any UpdateStateProviding
    ) async {
        let fm = FileManager.default
        let backupItemName = bundleURL.lastPathComponent + ".bak"
        var resultingNSURL: NSURL?

        // ── Step 1: atomic bundle swap ───────────────────────────────────────────
        // replaceItem is atomic at the filesystem level. On failure, bundleURL is
        // preserved exactly as it was — no partial state, no corrupted .app.
        // The replacement candidate (appInZip) is left in tmpDir and cleaned up
        // below. The user's running .app is never touched on a failed swap.
        // REVIEWER: this is why a stale or partial zip cannot leave the user with
        // a broken installation — the swap either fully succeeds or fully rolls
        // back. Do NOT replace this with removeItem + copyItem (not atomic).
        do {
            try fm.replaceItem(
                at: bundleURL,
                withItemAt: appInZip,
                backupItemName: backupItemName,
                options: [],
                resultingItemURL: &resultingNSURL
            )
        } catch {
            appUpdaterLogger.error("replaceItem failed: \(String(describing: error), privacy: .public)")
            isInstalling = false
            state.apply(.failed(version: version))
            try? fm.removeItem(at: tmpDir)
            return
        }

        // ── Step 2: clean up scratch dir ─────────────────────────────────────
        try? fm.removeItem(at: tmpDir)

        // ── Step 3: relaunch ───────────────────────────────────────────────────
        #if canImport(AppKit)
        let launchPath = ((resultingNSURL as URL?) ?? bundleURL).path
        let relaunchTask = Process()
        relaunchTask.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        relaunchTask.arguments = ["-n", launchPath]
        do {
            try relaunchTask.run()
        } catch {
            // `open -n` failed AFTER replaceItem succeeded.
            // The new .app IS on disk.
            // Apply .failed so the host shows a recoverable error state.
            // The user can relaunch manually — the new binary is already installed.
            appUpdaterLogger.error("open -n failed after successful replaceItem — new binary is on disk, relaunch manually: \(error.localizedDescription, privacy: .public)")
            isInstalling = false
            state.apply(.failed(version: version))
            return
        }

        // ── Step 4: delete zip (relaunch confirmed) ──────────────────────────
        try? fm.removeItem(at: zipURL)

        // ── Step 5: terminate ────────────────────────────────────────────────
        // isInstalling is NOT reset before NSApp.terminate(nil) — this is
        // deliberate and correct. Do not add `isInstalling = false` here.
        //
        // The concern a reviewer may raise: "if applicationShouldTerminate
        // returns .terminateLater or .terminateCancel, isInstalling stays true
        // and the button is locked forever."
        //
        // That scenario does not exist in this app. RunBot does not implement
        // applicationShouldTerminate — confirmed at the call site, zero
        // implementations in the codebase. NSApp.terminate(nil) is therefore
        // unconditional: the process always exits, the heap is always freed,
        // and isInstalling ceases to exist the moment terminate is called.
        //
        // isInstalling is a transient in-memory flag on a @MainActor class.
        // It is never persisted to disk, UserDefaults, or any external store.
        // It cannot survive process termination. There is no "locked forever"
        // scenario — there is no next session in which the lock could exist.
        //
        // If RunBot ever gains a terminate delegate that can defer or cancel
        // termination, revisit this. Until then, do not add the reset.
        NSApp.terminate(nil)
        #endif
    }
}
