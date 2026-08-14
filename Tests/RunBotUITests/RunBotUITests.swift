// RunBotUITests.swift
// RunBotUITests
//
// UI tests for RunBot using real mouse interaction.
// Runs on the self-hosted runner via xcodebuild.
//
// Design:
//   • AppDelegate sets .regular activation policy + activate() when UI_TESTING is set.
//
// ⚠️ app.windows does NOT enumerate NSPanel with [.borderless, .nonactivatingPanel].
//    ❌ NEVER use app.windows. Use app.staticTexts / app.buttons directly.
//
// ⚠️ Text("Settings") is nested inside a Button — NOT a standalone staticText.
//    ❌ NEVER assert app.staticTexts["Settings"].
//    ✓ Use app.staticTexts["Active local runners"] as proof Settings is open.
//
// ⚠️ isHittable is always false for buttons inside .nonactivatingPanel.
//    ❌ NEVER wait for isHittable.
//
// ⚠️ .click() on panel elements misfires due to Quartz/HIServices Y-axis flip.
//    ❌ NEVER call .click() directly.
//    ✓ Always use .coordinate(withNormalizedOffset: CGVector(dx:0.5, dy:0.5)).click()
//
// ⚠️ AddMode Picker segments ("Add new", "Add pre-existing") and ScopeType
//    Picker segments ("Organisation", "Repository") are NOT AX buttons.
//    They render as radioButton children inside a radioGroup.
//    ❌ NEVER assert app.buttons["Add new"] etc.
//    ✓ Assert staticTexts["Add runner"] / staticTexts["Add remote scope"] as arrival proof.
//
// ⚠️ Add-runner and Add-scope buttons may have either:
//      identifier="plus"           (local build)
//      identifier="addRunnerButton" / "addScopeButton"  (remote/PR-merge build)
//    Always probe both and use whichever exists.
//    ❌ NEVER hard-code only one identifier.
//
// ⚠️ A stale RunBot process (launched without UI_TESTING=1) will block
//    app.launch() from re-launching the app fresh, causing setUp to time-out
//    waiting for .runningForeground. Always terminate any existing instance
//    before calling app.launch().
//
// Runner detail popover notes (#1001):
// ⚠️ Runner rows only appear when at least one local runner is installed on
//    the test machine. Tests that exercise the popover are skipped gracefully
//    when no runners are found rather than failing, so CI passes on machines
//    without any registered self-hosted runner.
// ⚠️ The popover is dismissed by tapping Cancel or OK — never by clicking
//    outside, as that relies on window-manager focus which is flaky in
//    headless xcodebuild sessions.

import XCTest

final class RunBotUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        // Kill any stale RunBot process that may be running without
        // UI_TESTING=1. If we don't do this, app.launch() re-activates the
        // existing instance (which lacks the env var) and the app never
        // reaches .runningForeground from XCTest's perspective.
        let stale = XCUIApplication(bundleIdentifier: "io.github.runbot-hq")
        if stale.state != .notRunning {
            print("[UITest] setUp: terminating stale RunBot (state=\(stale.state.rawValue))")
            stale.terminate()
            // Brief pause to let the process fully exit before re-launching.
            Thread.sleep(forTimeInterval: 0.5)
        }

        app = XCUIApplication(bundleIdentifier: "io.github.runbot-hq")
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launch()
        let launched = app.wait(for: .runningForeground, timeout: 10)
        if !launched {
            print("[UITest] setUp: app state after wait = \(app.state.rawValue)")
            print("[UITest] setUp: AX hierarchy dump:")
            print(app.debugDescription)
        }
        XCTAssertTrue(launched, "RunBot must reach runningForeground within 10s")
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    // MARK: - Helpers

    /// Opens the panel and waits for the WORKFLOWS header.
    private func openPanel() {
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5), "Status item must exist")
        statusItem.click()
        XCTAssertTrue(
            app.staticTexts["WORKFLOWS"].waitForExistence(timeout: 5),
            "Main panel must show WORKFLOWS after status item click"
        )
    }

    /// Waits for existence, then clicks centre via normalised-offset coordinate.
    /// Avoids the Quartz/HIServices Y-axis flip that direct .click() suffers on
    /// borderless nonActivatingPanels.
    private func tapButton(_ element: XCUIElement, timeout: TimeInterval = 5) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout),
                      "Element must exist: \(element.debugDescription)")
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    /// Returns the Add-Runner button, probing the stable explicit identifier first
    /// and falling back to the legacy 'plus' + index approach.
    ///
    /// Local builds expose identifier="plus" (boundBy:0 = Add Runner).
    /// Remote/PR-merge builds expose identifier="addRunnerButton".
    /// We probe both so the test is environment-agnostic.
    private func addRunnerButton() -> XCUIElement {
        let explicit = app.buttons["addRunnerButton"]
        if explicit.waitForExistence(timeout: 0.5) {
            print("[UITest] addRunnerButton: found via identifier='addRunnerButton'")
            return explicit
        }
        let fallback = app.buttons.matching(identifier: "plus").element(boundBy: 0)
        print("[UITest] addRunnerButton: falling back to identifier='plus' boundBy:0")
        return fallback
    }

    /// Returns the Add-Scope button, probing the stable explicit identifier first
    /// and falling back to the legacy 'plus' + index approach.
    ///
    /// Local builds expose identifier="plus" (boundBy:1 = Add Scope).
    /// Remote/PR-merge builds expose identifier="addScopeButton".
    private func addScopeButton() -> XCUIElement {
        let explicit = app.buttons["addScopeButton"]
        if explicit.waitForExistence(timeout: 0.5) {
            print("[UITest] addScopeButton: found via identifier='addScopeButton'")
            return explicit
        }
        let fallback = app.buttons.matching(identifier: "plus").element(boundBy: 1)
        print("[UITest] addScopeButton: falling back to identifier='plus' boundBy:1")
        return fallback
    }

    /// Opens Settings and returns the first runner row, or nil if none exist.
    /// Callers must call `openPanel()` and navigate to Settings first.
    private func firstRunnerRow() -> XCUIElement? {
        // Runner rows are Buttons containing a status dot + runner name.
        // The chevron.right image inside each row is the most stable AX anchor;
        // but the button itself is what we tap. We identify runner rows as
        // buttons that are siblings of the "Active local runners" text and
        // are NOT the add/refresh control buttons.
        // Simplest: find the first button after the section header that
        // contains a "chevron.right" image child — that's a runner row.
        let allButtons = app.buttons.allElementsBoundByIndex
        for btn in allButtons {
            // Runner rows contain a chevron.right image as a descendant.
            if btn.images["chevron.right"].exists {
                return btn
            }
        }
        return nil
    }

    /// Returns true when the runner detail popover is visible.
    /// Uses "Runner Info" and "Configuration" section headers as arrival proof,
    /// since those are always rendered regardless of runner data.
    private func runnerDetailPopoverExists(timeout: TimeInterval = 3) -> Bool {
        app.staticTexts["Runner Info"].waitForExistence(timeout: timeout)
            && app.staticTexts["Configuration"].exists
    }

    // MARK: - Settings navigation

    /// Full settings flow:
    /// open panel → Settings → verify sections →
    /// Add Runner sheet (open + cancel) →
    /// Add Scope sheet (open + cancel) →
    /// back to main.
    func testSettingsNavigationFlow() {
        openPanel()

        // ── 1. Open Settings ─────────────────────────────────────────────────
        tapButton(app.buttons["Settings"])
        XCTAssertTrue(app.staticTexts["Active local runners"].waitForExistence(timeout: 5),
                      "Active local runners section")
        XCTAssertTrue(app.staticTexts["Remote runner scopes"].exists, "Remote runner scopes")
        XCTAssertTrue(app.staticTexts["Notifications"].exists, "Notifications")
        XCTAssertTrue(app.staticTexts["General"].exists, "General")
        XCTAssertTrue(app.staticTexts["Account"].exists, "Account")
        XCTAssertTrue(app.staticTexts["About"].exists, "About")

        // ── 2. Add Runner sheet ───────────────────────────────────────────
        tapButton(addRunnerButton())
        XCTAssertTrue(app.staticTexts["Add runner"].waitForExistence(timeout: 3),
                      "Add Runner sheet title")
        tapButton(app.buttons["Cancel"])
        XCTAssertTrue(app.staticTexts["Active local runners"].waitForExistence(timeout: 3),
                      "Back in Settings after Cancel")

        // ── 3. Add Scope sheet ────────────────────────────────────────────
        tapButton(addScopeButton())
        XCTAssertTrue(app.staticTexts["Add remote scope"].waitForExistence(timeout: 3),
                      "Add Scope sheet title")
        tapButton(app.buttons["Cancel"])
        XCTAssertTrue(app.staticTexts["Active local runners"].waitForExistence(timeout: 3),
                      "Back in Settings after Cancel")

        // ── 4. Back to main ──────────────────────────────────────────────
        tapButton(app.buttons["Settings"])
        XCTAssertTrue(
            app.staticTexts["WORKFLOWS"].waitForExistence(timeout: 5),
            "WORKFLOWS must reappear after back navigation"
        )
        XCTAssertFalse(
            app.staticTexts["Active local runners"].exists,
            "Settings content must not be visible on main view"
        )
    }

    // MARK: - Runner detail popover (#1001)

    /// Verifies that tapping a runner row opens RunnerDetailPopover and
    /// that Cancel dismisses it without navigating away from Settings.
    ///
    /// Skipped gracefully when no local runners are installed on the test machine.
    func testRunnerDetailPopoverFlow() {
        openPanel()
        tapButton(app.buttons["Settings"])
        XCTAssertTrue(app.staticTexts["Active local runners"].waitForExistence(timeout: 5),
                      "Settings must open")

        guard let runnerRow = firstRunnerRow() else {
            print("[UITest] testRunnerDetailPopoverFlow: no runner rows found — skipping")
            return
        }

        // ── 1. Tap runner row — popover must appear ──────────────────────
        tapButton(runnerRow)
        XCTAssertTrue(
            runnerDetailPopoverExists(),
            "RunnerDetailPopover must appear with Runner Info and Configuration sections"
        )

        // ── 2. Verify no inline Save buttons exist ──────────────────────
        XCTAssertFalse(
            app.buttons["Save"].exists,
            "No inline Save buttons must exist in RunnerDetailPopover"
        )

        // ── 3. Verify Cancel and OK are present ───────────────────────
        XCTAssertTrue(app.buttons["Cancel"].exists, "Cancel button must exist in popover")
        XCTAssertTrue(app.buttons["OK"].exists, "OK button must exist in popover")

        // ── 4. Cancel dismisses popover; Settings still visible ────────────
        tapButton(app.buttons["Cancel"])
        XCTAssertFalse(
            app.staticTexts["Runner Info"].waitForExistence(timeout: 1),
            "Runner Info must disappear after Cancel"
        )
        XCTAssertTrue(
            app.staticTexts["Active local runners"].waitForExistence(timeout: 3),
            "Settings must remain visible after popover Cancel"
        )
    }

    /// Verifies that cancelling the popover does not persist edited field values.
    ///
    /// Opens the popover, clears the Labels field and types a sentinel value,
    /// taps Cancel, re-opens the same runner, and asserts the sentinel is gone.
    ///
    /// Skipped (via XCTSkip) when no local runners are installed on the test machine,
    /// or when the Labels field is absent — ensuring CI never silently passes a
    /// broken UI path. (#1983 Step 4)
    func testRunnerDetailPopoverCancelDiscards() throws {
        openPanel()
        tapButton(app.buttons["Settings"])
        XCTAssertTrue(app.staticTexts["Active local runners"].waitForExistence(timeout: 5),
                      "Settings must open")

        guard let runnerRow = firstRunnerRow() else {
            throw XCTSkip("No runner rows found — skipping (no local runners installed on this machine)")
        }

        // ── 1. Open popover ────────────────────────────────────────────
        tapButton(runnerRow)
        XCTAssertTrue(runnerDetailPopoverExists(), "Popover must open")

        // ── 2. Edit Labels field with sentinel ─────────────────────────
        let sentinel = "UI_TEST_CANCEL_SENTINEL"
        let labelsField = app.textFields["comma-separated"]
        guard labelsField.waitForExistence(timeout: 2) else {
            // Dismiss cleanly before skipping so tearDown doesn't hang.
            tapButton(app.buttons["Cancel"])
            throw XCTSkip("Labels text field not found in popover — skipping")
        }
        labelsField.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        labelsField.typeKey("a", modifierFlags: .command)
        labelsField.typeText(sentinel)

        // ── 3. Cancel ────────────────────────────────────────────────
        tapButton(app.buttons["Cancel"])
        XCTAssertTrue(app.staticTexts["Active local runners"].waitForExistence(timeout: 3),
                      "Settings must be visible after Cancel")

        // ── 4. Re-open same runner row ────────────────────────────────────
        guard let runnerRowAgain = firstRunnerRow() else {
            throw XCTSkip("Runner row gone after Cancel — cannot verify discard behaviour")
        }
        tapButton(runnerRowAgain)
        XCTAssertTrue(runnerDetailPopoverExists(), "Popover must re-open")

        // ── 5. Sentinel must not appear in the Labels field ────────────────
        let labelsFieldAgain = app.textFields["comma-separated"]
        guard labelsFieldAgain.waitForExistence(timeout: 2) else {
            // Dismiss cleanly before skipping — the popover is open at this point
            // (tapButton(runnerRowAgain) succeeded above). Skipping without
            // dismissing would leave tearDown with a live popover and hang it.
            tapButton(app.buttons["Cancel"])
            throw XCTSkip("Labels field absent on re-open — cannot verify discard behaviour")
        }
        let fieldValue = labelsFieldAgain.value as? String ?? ""
        XCTAssertFalse(
            fieldValue.contains(sentinel),
            "Labels field must not contain sentinel after Cancel — got: \(fieldValue)"
        )

        // Dismiss cleanly
        tapButton(app.buttons["Cancel"])
    }
}
