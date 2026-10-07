import XCTest

// These tests drive a UIKit app (iPhone, iPad, Mac Catalyst). The whole file
// sits in the UIKit branch so every `targetEnvironment` check below is nested
// inside it, the order AGENTS.md requires: Catalyst imports UIKit *and*
// AppKit, so UIKit is always asked first.
#if canImport(UIKit)
    import UIKit

    #if targetEnvironment(macCatalyst)
        import AppKit
    #endif

    final class MobileGhosttyAppUITests: XCTestCase {
        private var app: XCUIApplication!

        override func setUpWithError() throws {
            continueAfterFailure = false
            if ProcessInfo.processInfo.environment["LIBGHOSTTY_INLINE_SELECTION"] == "0",
               name.contains("testInline")
            {
                throw XCTSkip("Inline selection is disabled in this test pass")
            }
            app = XCUIApplication()
            app.launchArguments = ["--ui-testing"]
            if ProcessInfo.processInfo.environment["LIBGHOSTTY_INLINE_SELECTION"] == "0" {
                app.launchArguments.append("--no-inline-selection")
            }
            installSystemAlertHandler()
            #if !targetEnvironment(macCatalyst)
                XCUIDevice.shared.orientation = launchOrientation
            #endif
            launchApp()
        }

        /// Comfortably past the 0.7 s long-press recognizer. A loaded runner
        /// can shorten a synthesized press, and at 0.8 s an iPad press ended
        /// as a single tap: no menu, and the keyboard toggled away.
        private static let longPressDuration: TimeInterval = 1.2

        /// Pins the app to English so menu titles and key labels match the
        /// strings below on any host language (a Chinese system localizes
        /// UIKit's edit menu and the keyboard's Space and Return keys).
        private func launchApp() {
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
        }

        override func tearDownWithError() throws {
            if app != nil {
                capture("final-state")
            }
            #if !targetEnvironment(macCatalyst)
                if XCUIDevice.shared.orientation != launchOrientation {
                    XCUIDevice.shared.orientation = launchOrientation
                }
            #endif
            app = nil
        }

        #if !targetEnvironment(macCatalyst)
            private var launchOrientation: UIDeviceOrientation {
                UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
            }
        #endif

        // MARK: - Lifecycle and stress

        func testTypedCommandBurstProducesEveryOutputInOrder() throws {
            let terminal = try requireTerminalInteractionTarget()
            typeTerminalText("clear\n", in: terminal)
            let expected = (1 ... 8).map { String(format: "burst-%02d", $0) }
            let burst = expected.map { "echo \($0)\n" }.joined()
            typeTerminalText(burst, in: terminal)

            let viewport = waitForViewport("all burst outputs") { text in
                Self.outputLines(of: text).filter { $0.hasPrefix("burst-") } == expected
            }
            XCTAssertNotNil(viewport)
            capture("burst-output")
        }

        func testBackgroundForegroundKeepsTerminalUsable() throws {
            let terminal = try requireTerminalInteractionTarget()
            typeTerminalText("echo before-background\n", in: terminal)
            // A fresh hosted simulator can finish its first keyboard delivery
            // after typeText returns. Wait for the output before backgrounding.
            waitForOutputLine("before-background", timeout: 20)

            for cycle in 1 ... 3 {
                sendAppToBackgroundAndBack()
                capture("foreground-\(cycle)")
                XCTAssertTrue(
                    Self.outputLines(of: viewportText()).contains("before-background"),
                    "Earlier output was lost after background cycle \(cycle)",
                )
                typeTerminalText("echo after-foreground-\(cycle)\n", in: terminal)
                waitForOutputLine("after-foreground-\(cycle)")
            }
        }

        func testLongOutputScrollsBackAndReturnsOnTyping() throws {
            let terminal = try requireTerminalInteractionTarget()
            typeTerminalText(String(repeating: "help\n", count: 6) + "echo long-output-done\n", in: terminal)
            // Trimmed lines lose the prompt's trailing space.
            let bottom = waitForViewport("six help blocks") { text in
                let lines = Self.outputLines(of: text)
                return lines.contains("long-output-done") && lines.last?.hasSuffix("%") == true
            }
            let bottomText = try XCTUnwrap(bottom)

            scrollTerminalIntoHistory(terminal)
            waitForViewport("viewport scrolled into history") { $0 != bottomText }
            capture("scrolled-into-history")

            typeTerminalText("echo after-scroll\n", in: terminal)
            waitForOutputLine("after-scroll")
            capture("scrolled-back-on-typing")
        }

        func testRelaunchStartsAFreshUsableTerminal() throws {
            var terminal = try requireTerminalInteractionTarget()
            typeTerminalText("echo before-relaunch\n", in: terminal)
            waitForOutputLine("before-relaunch")

            app.terminate()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
            launchApp()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

            terminal = try requireTerminalInteractionTarget()
            let fresh = waitForViewport("welcome banner after relaunch") {
                $0.contains("GhosttyKit Sandbox Demo")
            }
            XCTAssertFalse(fresh?.contains("before-relaunch") ?? true)
            typeTerminalText("echo after-relaunch\n", in: terminal)
            waitForOutputLine("after-relaunch")
        }

        #if targetEnvironment(macCatalyst)
            func testWindowResizeChangesGridAndKeepsTerminalUsable() throws {
                let terminal = try requireTerminalInteractionTarget()
                let original = try XCTUnwrap(terminalGridSize(in: terminal))

                let window = app.windows.firstMatch
                let originalWidth = window.frame.width
                // The left edge: a window as wide as the screen has its right
                // edge on the display border, where a drag does not resize.
                dragWindowLeftEdge(window, by: 240)
                waitForFrameWidth(of: window) { $0 < originalWidth - 100 }
                let narrowed = try XCTUnwrap(terminalGridSize(in: terminal))
                let narrowedWidth = window.frame.width
                XCTAssertLessThan(narrowed.columns, original.columns)
                capture("window-narrowed")

                dragWindowLeftEdge(window, by: -240)
                // The window manager can leave screen-edge margins when growing
                // back. Verify both resize directions without requiring the old frame.
                waitForFrameWidth(of: window) { $0 > narrowedWidth + 100 }
                let restored = try XCTUnwrap(terminalGridSize(in: terminal))
                XCTAssertGreaterThan(restored.columns, narrowed.columns)
                typeTerminalText("echo after-resize\n", in: terminal)
                waitForOutputLine("after-resize")
            }
        #else
            func testRotationResizesGridAndKeepsTerminalUsable() throws {
                let terminal = try requireTerminalInteractionTarget()
                let original = try XCTUnwrap(terminalGridSize(in: terminal))
                let rotated: UIDeviceOrientation = isIPad ? .portrait : .landscapeLeft

                XCUIDevice.shared.orientation = rotated
                let turned = try XCTUnwrap(waitForGridSize(in: terminal) { $0.columns != original.columns })
                if isIPad {
                    XCTAssertLessThan(turned.columns, original.columns)
                } else {
                    XCTAssertGreaterThan(turned.columns, original.columns)
                }
                capture("rotated")
                typeTerminalText("echo rotated\n", in: terminal)
                waitForOutputLine("rotated")

                XCUIDevice.shared.orientation = launchOrientation
                let restored = try XCTUnwrap(waitForGridSize(in: terminal) { $0.columns == original.columns })
                XCTAssertEqual(restored.columns, original.columns)
                typeTerminalText("echo rotated-back\n", in: terminal)
                waitForOutputLine("rotated-back")
            }

            func testSoftwareKeyboardToggleResizesAndKeepsTerminalUsable() throws {
                let terminal = try requireTerminalInteractionTarget()
                XCTAssertTrue(prepareTerminalForTyping(terminal))
                let keyboard = app.keyboards.firstMatch
                guard keyboard.waitForExistence(timeout: 3) else {
                    throw XCTSkip("No software keyboard: the simulator has a hardware keyboard connected")
                }
                let shownGrid = try XCTUnwrap(terminalGridSize(in: terminal))
                let shownHeight = terminal.frame.height

                for cycle in 1 ... 3 {
                    tapTerminal(in: terminal)
                    XCTAssertTrue(keyboard.waitForNonExistence(timeout: 4), "Keyboard stayed up, cycle \(cycle)")
                    XCTAssertGreaterThan(terminal.frame.height, shownHeight, "Terminal did not grow, cycle \(cycle)")
                    tapTerminal(in: terminal)
                    XCTAssertTrue(keyboard.waitForExistence(timeout: 4), "Keyboard did not return, cycle \(cycle)")
                }
                capture("keyboard-toggled")

                let finalGrid = try XCTUnwrap(terminalGridSize(in: terminal))
                XCTAssertEqual(finalGrid, shownGrid)
                typeTerminalText("echo after-keyboard-toggle\n", in: terminal)
                waitForOutputLine("after-keyboard-toggle")
            }

            /// A tap far below the prompt raises the keyboard without
            /// pushing the screen's few lines into scrollback: the tap's
            /// click must not pin a blank row the resize would trim.
            func testLowTapRaisingKeyboardKeepsScreenContent() throws {
                let terminal = try requireTerminalInteractionTarget()
                XCTAssertTrue(prepareTerminalForTyping(terminal))
                let keyboard = app.keyboards.firstMatch
                guard keyboard.waitForExistence(timeout: 3) else {
                    throw XCTSkip("No software keyboard: the simulator has a hardware keyboard connected")
                }
                typeTerminalText("clear\necho low-tap-anchor\n", in: terminal)
                waitForOutputLine("low-tap-anchor")

                tapTerminal(in: terminal)
                XCTAssertTrue(keyboard.waitForNonExistence(timeout: 4))
                let low = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92))
                if isIPad {
                    low.tap()
                } else {
                    low.press(forDuration: 0.01)
                }
                XCTAssertTrue(keyboard.waitForExistence(timeout: 4))
                // Let the keyboard's resize reach the grid before reading it.
                RunLoop.current.run(until: Date().addingTimeInterval(1.5))
                waitForOutputLine("low-tap-anchor")
                capture("low-tap-keyboard-raised")
            }
        #endif

        // MARK: - Lifecycle helpers

        private struct GridSize: Equatable {
            var columns: Int
            var rows: Int
        }

        private var outputElement: XCUIElement {
            app.descendants(matching: .any)["terminal.output"].firstMatch
        }

        private func viewportText() -> String {
            (outputElement.value as? String) ?? ""
        }

        private static func outputLines(of viewport: String) -> [String] {
            viewport.components(separatedBy: "\n").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
        }

        @discardableResult
        private func waitForViewport(
            _ description: String,
            timeout: TimeInterval = 8,
            until condition: (String) -> Bool,
        ) -> String? {
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                let text = viewportText()
                if condition(text) {
                    return text
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            } while Date() < deadline
            log("viewport-timeout", "\(description)\n---\n\(viewportText())")
            XCTFail("Viewport never showed: \(description)")
            return nil
        }

        private func waitForOutputLine(_ line: String, timeout: TimeInterval = 8) {
            waitForViewport("output line \(line)", timeout: timeout) {
                Self.outputLines(of: $0).contains(line)
            }
        }

        /// Clears the screen and runs `size`, so the one `columns:` line on
        /// screen is the grid the shell sees now.
        private func terminalGridSize(in terminal: XCUIElement) -> GridSize? {
            typeTerminalText("clear\nsize\n", in: terminal)
            var grid: GridSize?
            waitForViewport("size output") { text in
                grid = Self.parseGridSize(text)
                return grid != nil
            }
            return grid
        }

        private func waitForGridSize(
            in terminal: XCUIElement,
            timeout: TimeInterval = 10,
            until condition: (GridSize) -> Bool,
        ) -> GridSize? {
            let deadline = Date().addingTimeInterval(timeout)
            var last: GridSize?
            repeat {
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                last = terminalGridSize(in: terminal)
                if let last, condition(last) {
                    return last
                }
            } while Date() < deadline
            XCTFail("Grid size never reached the expected value; last \(String(describing: last))")
            return nil
        }

        private static func parseGridSize(_ viewport: String) -> GridSize? {
            for line in outputLines(of: viewport).reversed() where line.hasPrefix("columns: ") {
                let numbers = line.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                guard numbers.count >= 2 else { continue }
                return GridSize(columns: numbers[0], rows: numbers[1])
            }
            return nil
        }

        private func sendAppToBackgroundAndBack() {
            #if targetEnvironment(macCatalyst)
                // A Cmd+H sent while the app is still settling after the
                // previous unhide can be dropped; one retry tells that apart
                // from an app that cannot hide.
                var result = XCTWaiter.Result.timedOut
                for _ in 1 ... 2 where result != .completed {
                    app.typeKey("h", modifierFlags: .command)
                    let hidden = XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "isHittable == false"),
                        object: app.windows.firstMatch,
                    )
                    result = XCTWaiter.wait(for: [hidden], timeout: 5)
                }
                XCTAssertEqual(result, .completed)
                app.activate()
                XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
            #else
                var result = XCTWaiter.Result.timedOut
                for _ in 1 ... 2 where result != .completed {
                    XCUIDevice.shared.press(.home)
                    let backgrounded = XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "state != %d", XCUIApplication.State.runningForeground.rawValue),
                        object: app,
                    )
                    result = XCTWaiter.wait(for: [backgrounded], timeout: 5)
                }
                XCTAssertEqual(result, .completed)
                app.activate()
                XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
            #endif
        }

        private func scrollTerminalIntoHistory(_ terminal: XCUIElement) {
            #if targetEnvironment(macCatalyst)
                terminal.scroll(byDeltaX: 0, deltaY: 300)
            #else
                terminal.swipeDown(velocity: .fast)
            #endif
        }

        #if targetEnvironment(macCatalyst)
            private func dragWindowLeftEdge(_ window: XCUIElement, by dx: CGFloat) {
                let originalWidth = window.frame.width
                for _ in 0 ..< 2 {
                    let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
                        .withOffset(CGVector(dx: 1, dy: 0))
                    edge.press(forDuration: 0.3, thenDragTo: edge.withOffset(CGVector(dx: dx, dy: 0)))
                    if abs(window.frame.width - originalWidth) > 20 {
                        return
                    }
                }
            }

            private func waitForFrameWidth(of window: XCUIElement, _ condition: (CGFloat) -> Bool) {
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline {
                    if condition(window.frame.width) {
                        return
                    }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                }
                XCTFail("Window width never changed as expected; now \(window.frame.width)")
            }
        #endif

        #if !targetEnvironment(macCatalyst)
            func testInlineLongPressSelectionCopiesWithAccessoryCommand() throws {
                app.terminate()
                app.launchArguments = ["--ui-testing", "--ui-testing-copy-fixture"]
                launchApp()
                let terminal = try requireTerminalInteractionTarget()
                waitForOutputLine("touch-copy-ready")
                requireSoftwareKeyboard(in: terminal)
                pointerCell(in: terminal, column: 4).press(forDuration: Self.longPressDuration)
                XCTAssertTrue(app.menuItems["Select"].waitForExistence(timeout: 4))
                app.menuItems["Select"].tap()
                XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 4))
                let command = app.buttons["Command"]
                XCTAssertTrue(command.waitForExistence(timeout: 4))
                command.tap()
                app.keys["c"].tap()
                XCTAssertEqual(copiedSelectionText(in: terminal, timeout: 3), "touch-copy-ready")
                XCTAssertFalse(app.menuItems["Copy"].exists)

                // Copy spends the armed modifier; ordinary typing and the
                // next Command shortcut must still reach the shell afterwards.
                // The visible suffix confirms that delayed Space delivery has
                // finished before arming Command for the next key.
                tapSoftwareKeys("echo x")
                waitForViewport("ordinary software keys committed") {
                    Self.outputLines(of: $0).last?.hasSuffix("% echo x") == true
                }
                command.tap()
                app.keys["v"].tap()
                app.buttons["Return"].tap()
                waitForOutputLine("xtouch-copy-ready")
            }

            func testInlinePublicKeyCopiesWithExplicitAndStickyCommand() throws {
                for sticky in [false, true] {
                    app.terminate()
                    app.launchArguments = ["--ui-testing", "--ui-testing-copy-fixture", "--ui-testing-public-copy"]
                    if sticky {
                        app.launchArguments.append("--ui-testing-sticky-copy")
                    }
                    launchApp()
                    let terminal = try requireTerminalInteractionTarget()
                    waitForOutputLine("touch-copy-ready")
                    // Before the copy: raising the keyboard can type through
                    // XCTest, which replaces the pasteboard.
                    requireSoftwareKeyboard(in: terminal)
                    pointerCell(in: terminal, column: 4).press(forDuration: Self.longPressDuration)
                    XCTAssertTrue(app.menuItems["Select"].waitForExistence(timeout: 4))
                    app.menuItems["Select"].tap()
                    XCTAssertTrue(app.menuItems["Send Key"].waitForExistence(timeout: 4))
                    app.menuItems["Send Key"].tap()
                    XCTAssertEqual(copiedSelectionText(in: terminal, timeout: 3), "touch-copy-ready")
                    XCTAssertFalse(app.menuItems["Copy"].exists)

                    // A public key spends an armed modifier exactly once.
                    tapSoftwareKeys("echo x")
                    waitForViewport("ordinary software keys committed") {
                        Self.outputLines(of: $0).last?.hasSuffix("% echo x") == true
                    }
                    app.buttons["Command"].tap()
                    app.keys["v"].tap()
                    app.buttons["Return"].tap()
                    waitForOutputLine("xtouch-copy-ready")
                }
            }

            func testInlineKeyCommandsAndAccessoryArrowsClearSelection() throws {
                app.terminate()
                app.launchArguments = ["--ui-testing", "--ui-testing-copy-fixture", "--ui-testing-key-commands"]
                launchApp()
                let terminal = try requireTerminalInteractionTarget()
                waitForOutputLine("touch-copy-ready")
                for input in ["arrow", "control", "escape"] {
                    let point = pointerCell(in: terminal, column: 4)
                    point.press(forDuration: Self.longPressDuration)
                    XCTAssertTrue(app.menuItems["Select"].waitForExistence(timeout: 4))
                    app.menuItems["Select"].tap()
                    XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 4))
                    switch input {
                    case "arrow": app.buttons["Left Arrow"].tap()
                    case "control": revealNativeMenuItem("Send Control A").tap()
                    default: revealNativeMenuItem("Send Escape").tap()
                    }
                    XCTAssertTrue(app.menuItems["Copy"].waitForNonExistence(timeout: 4))
                    // Reopening must offer Select: dismissing the menu alone
                    // would retain the range and offer Copy again.
                    point.press(forDuration: Self.longPressDuration)
                    XCTAssertTrue(app.menuItems["Select"].waitForExistence(timeout: 4))
                    XCTAssertFalse(app.menuItems["Copy"].exists)
                    terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.9)).tap()
                }
            }

            func testInlineLongPressSelectionCopiesWithKeyboard() throws {
                let terminal = try requireTerminalInteractionTarget()
                typeTerminalText("clear\necho touch-copy-ready\n", in: terminal)
                waitForOutputLine("touch-copy-ready")
                pointerCell(in: terminal, column: 4).press(forDuration: Self.longPressDuration)
                XCTAssertTrue(app.menuItems["Select"].waitForExistence(timeout: 4))
                app.menuItems["Select"].tap()
                XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 4))
                XCTAssertTrue(waitForKeyboardFocus(in: terminal, timeout: 4))
                app.typeKey("c", modifierFlags: .command)
                XCTAssertTrue(app.menuItems["Copy"].waitForNonExistence(timeout: 4))
                XCTAssertEqual(copiedSelectionText(in: terminal, timeout: 3), "touch-copy-ready")
            }

            func testInlineTouchSelectionKeepsKeyboardHidden() throws {
                for capturesMouse in [false, true] {
                    app.terminate()
                    app.launchArguments = ["--ui-testing", "--ui-testing-hidden-selection"]
                    if capturesMouse {
                        app.launchArguments.append("--ui-testing-mouse-capture")
                    }
                    launchApp()
                    let terminal = try requireTerminalInteractionTarget()
                    waitForOutputLine("touch-copy-ready")
                    XCTAssertFalse(app.keyboards.firstMatch.exists)

                    let word = pointerCell(in: terminal, column: 4)
                    for taps in [2, 3] {
                        if taps == 2 {
                            word.doubleTap()
                        } else {
                            terminal.tap(withNumberOfTaps: 3, numberOfTouches: 1)
                        }
                        XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 4))
                        XCTAssertFalse(app.keyboards.firstMatch.exists)
                        app.menuItems["Copy"].tap()
                        XCTAssertTrue(app.menuItems["Copy"].waitForNonExistence(timeout: 4))
                        XCTAssertEqual(copiedSelectionText(in: terminal, timeout: 3), "touch-copy-ready")
                        XCTAssertFalse(app.keyboards.firstMatch.exists)
                    }

                    for action in ["Select", "Select All"] {
                        word.press(forDuration: Self.longPressDuration)
                        XCTAssertTrue(app.menuItems[action].waitForExistence(timeout: 4))
                        XCTAssertFalse(app.keyboards.firstMatch.exists)
                        app.menuItems[action].tap()
                        XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 4))
                        XCTAssertFalse(app.keyboards.firstMatch.exists)
                        if action == "Select" {
                            app.menuItems["Select All"].tap()
                            XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 4))
                            XCTAssertFalse(app.keyboards.firstMatch.exists)
                        }
                        app.menuItems["Copy"].tap()
                        XCTAssertTrue(app.menuItems["Copy"].waitForNonExistence(timeout: 4))
                        XCTAssertTrue((copiedSelectionText(in: terminal, timeout: 3) ?? "").contains("touch-copy-ready"))
                        XCTAssertFalse(app.keyboards.firstMatch.exists)
                    }
                }
            }

            func testInlineSelectFromWhitespaceAllowsBothHandlesToTrimTheText() throws {
                app.terminate()
                app.launchArguments = ["--ui-testing", "--ui-testing-hidden-selection"]
                launchApp()
                let terminal = try requireTerminalInteractionTarget()
                waitForOutputLine("touch-copy-ready")
                pointerCell(in: terminal, column: 24).press(forDuration: Self.longPressDuration)
                XCTAssertTrue(app.menuItems["Select"].waitForExistence(timeout: 4))
                app.menuItems["Select"].tap()
                XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 4))
                capture("inline-select-row-text")

                // Select ends at the text, so its handle can trim within the row.
                pointerCell(in: terminal, column: 16, fraction: 0).press(
                    forDuration: 0.1,
                    thenDragTo: pointerCell(in: terminal, column: 10, fraction: 0),
                )
                XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 4))
                // Grab inside the handle's hit target, away from the screen edge
                // where XCTest clamps touch coordinates, and move six columns.
                pointerCell(in: terminal, column: 2, fraction: 0).press(
                    forDuration: 0.1,
                    thenDragTo: pointerCell(in: terminal, column: 8, fraction: 0),
                )
                XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 4))
                capture("inline-select-row-trimmed")
                app.menuItems["Copy"].tap()
                // UIKit's pan threshold and XCTest's interpolation can shift the
                // final cell. Both ends must still trim within the original row.
                let copied = try XCTUnwrap(copiedSelectionText(in: terminal, timeout: 3))
                XCTAssertTrue("touch-copy-ready".contains(copied))
                XCTAssertTrue(copied.contains("copy"))
                XCTAssertFalse(copied.hasPrefix("touch-"))
                XCTAssertFalse(copied.hasSuffix("-ready"))
                XCTAssertFalse(app.keyboards.firstMatch.exists)
            }

            func testInlineSelectionSwitchesBetweenTouchPointerAndKeyboard() throws {
                guard isIPad else { throw XCTSkip("Pointer mixing requires iPad") }
                app.terminate()
                app.launchArguments = ["--ui-testing"]
                launchApp()
                let terminal = try requireTerminalInteractionTarget()
                typeTerminalText("clear\necho mixed-input left middle right\n", in: terminal)
                waitForOutputLine("mixed-input left middle right")
                let word = pointerCell(in: terminal, column: 4)
                word.doubleTap()
                XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 4))
                terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.8)).click()
                XCTAssertTrue(app.menuItems["Copy"].waitForNonExistence(timeout: 4))

                typeTerminalText("clear\necho \(iPadPointerSelectionPrefix)\(expectedPointerSelection)\n", in: terminal)
                waitForOutputLine("\(iPadPointerSelectionPrefix)\(expectedPointerSelection)")
                dismissTerminalKeyboard(in: terminal)
                let rightClick = dragIPadPointerSelection(in: terminal)
                openCopyMenuAndCopySelection(in: terminal, screenshotName: "mixed-pointer-copy", rightClickCoordinate: rightClick)

                typeTerminalText("clear\necho touch-copy-ready\n", in: terminal)
                waitForOutputLine("touch-copy-ready")
                pointerCell(in: terminal, column: 4).doubleTap()
                XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 4))
                XCTAssertTrue(waitForKeyboardFocus(in: terminal, timeout: 4))
                app.typeKey("c", modifierFlags: .command)
                XCTAssertTrue(app.menuItems["Copy"].waitForNonExistence(timeout: 4))
                let copied = try XCTUnwrap(copiedSelectionText(in: terminal, timeout: 3))
                XCTAssertEqual(copied, "touch-copy-ready")
                // XCTest's typeText can deliver through the pasteboard and
                // would replace the copy; hardware keys never touch it.
                for key in ["e", "c", "h", "o", XCUIKeyboardKey.space.rawValue] {
                    app.typeKey(key, modifierFlags: [])
                }
                app.typeKey("v", modifierFlags: .command)
                waitForViewport("touch selection pasted at the prompt") {
                    Self.outputLines(of: $0).last?.hasSuffix("% echo \(copied)") == true
                }
            }

            func testInlinePinchChangesTheGridAndKeepsTypingUsable() throws {
                app.terminate()
                app.launchArguments = ["--ui-testing"]
                launchApp()
                let terminal = try requireTerminalInteractionTarget()
                let original = try XCTUnwrap(terminalGridSize(in: terminal))
                terminal.pinch(withScale: 1.4, velocity: 1.0)
                let zoomed = try XCTUnwrap(waitForGridSize(in: terminal) { $0.columns < original.columns })
                XCTAssertLessThan(zoomed.columns, original.columns)
                typeTerminalText("echo after-pinch\n", in: terminal)
                waitForOutputLine("after-pinch")
            }

            func testInlineSingleTapTogglesKeyboardAndKeepsNativeAccessory() throws {
                app.terminate()
                app.launchArguments = ["--ui-testing"]
                launchApp()
                let terminal = try requireTerminalInteractionTarget()
                typeTerminalText("echo tap-keyboard\n", in: terminal)
                XCTAssertTrue(app.buttons["Control"].exists)
                tapTerminal(in: terminal)
                let noFocus = NSPredicate(format: "hasKeyboardFocus == false")
                expectation(for: noFocus, evaluatedWith: terminal)
                waitForExpectations(timeout: 4)
                XCTAssertFalse(app.buttons["Control"].isHittable)
                capture("inline-keyboard-hidden")
                tapTerminal(in: terminal)
                XCTAssertTrue(waitForKeyboardFocus(in: terminal, timeout: 4))
                XCTAssertTrue(app.buttons["Control"].waitForExistence(timeout: 4))
                XCTAssertFalse(app.menuItems["Select"].exists)
                capture("inline-keyboard-shown")
            }

            func testInlineSingleTapClosesMenuBeforeTogglingKeyboard() throws {
                app.terminate()
                app.launchArguments = ["--ui-testing"]
                launchApp()
                let terminal = try requireTerminalInteractionTarget()
                typeTerminalText("echo menu-priority\n", in: terminal)
                terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.15)).press(forDuration: Self.longPressDuration)
                XCTAssertTrue(app.menuItems["Select"].waitForExistence(timeout: 4))
                terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.8)).tap()
                XCTAssertFalse(app.menuItems["Select"].exists)
                XCTAssertTrue(waitForKeyboardFocus(in: terminal, timeout: 2))
                tapTerminal(in: terminal)
                expectation(for: NSPredicate(format: "hasKeyboardFocus == false"), evaluatedWith: terminal)
                waitForExpectations(timeout: 4)
            }

            func testInlineSelectionMenuAndCopy() throws {
                app.terminate()
                app.launchArguments = ["--ui-testing", "--ui-testing-pasteboard", "--ui-testing-host-menu"]
                launchApp()
                let terminal = try requireTerminalInteractionTarget()
                typeTerminalText("clear\n", in: terminal)
                typeTerminalText("echo inline-selection 你好\n", in: terminal)
                waitForOutputLine("inline-selection 你好")
                let point = pointerCell(in: terminal, column: 4)
                point.press(forDuration: Self.longPressDuration)
                XCTAssertTrue(app.menuItems["Select"].waitForExistence(timeout: 4), app.debugDescription)
                XCTAssertTrue(app.menuItems["Select All"].exists)
                XCTAssertTrue(app.menuItems["Paste"].exists)
                capture("inline-selection-menu")
                try assertSuppliedSystemMenuIsVisible()
                XCTAssertTrue(revealNativeMenuItem("Select").exists)
                capture("inline-selection-expanded")
                revealNativeMenuItem("Select").tap()
                XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 4), app.debugDescription)
                XCTAssertTrue(app.menuItems["Select All"].exists)
                XCTAssertTrue(app.menuItems["Paste"].exists)
                capture("inline-selection-word")
                let endHandle = pointerCell(in: terminal, column: "inline-selection".count, fraction: 0)
                // Finish beyond the wide glyph so event interpolation cannot
                // leave the handle just before its final cell.
                let extended = pointerCell(in: terminal, column: "inline-selection".count + 8)
                endHandle.press(forDuration: 0.1, thenDragTo: extended)
                XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 4))
                capture("inline-selection-drag")
                app.menuItems["Copy"].tap()
                XCTAssertEqual(copiedSelectionText(in: terminal, timeout: 2), "inline-selection 你好")
                // Select again after Copy clears the selection, then expand and Select All.
                point.press(forDuration: Self.longPressDuration)
                XCTAssertTrue(app.menuItems["Select"].waitForExistence(timeout: 4))
                app.menuItems["Select"].tap()
                XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 4))
                try assertSuppliedSystemMenuIsVisible()
                XCTAssertTrue(revealNativeMenuItem("Copy").exists)
                XCTAssertTrue(revealNativeMenuItem("Select All").exists)
                capture("inline-selection-selected-expanded")
                revealNativeMenuItem("Select All").tap()
                XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 4), app.debugDescription)
                capture("inline-selection-all")
                app.menuItems["Copy"].tap()
                XCTAssertTrue((copiedSelectionText(in: terminal, timeout: 2) ?? "").contains("inline-selection 你好"))

                let output = app.descendants(matching: .any)["terminal.output"].firstMatch
                let viewport = try XCTUnwrap(output.value as? String)
                let nearestLine = try XCTUnwrap(
                    viewport.components(separatedBy: .newlines)
                        .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                )
                // Select from empty space below the prompt, then copy the nearest text row.
                terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.8)).press(forDuration: Self.longPressDuration)
                XCTAssertTrue(app.menuItems["Select"].waitForExistence(timeout: 4))
                app.menuItems["Select"].tap()
                XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 4))
                app.menuItems["Copy"].tap()
                let copiedLine = try XCTUnwrap(copiedSelectionText(in: terminal, timeout: 2))
                XCTAssertEqual(
                    copiedLine.trimmingCharacters(in: .whitespacesAndNewlines),
                    nearestLine.trimmingCharacters(in: .whitespacesAndNewlines),
                )
            }

            func testInlineMenuHidesUnavailablePasteAndProvidesHostActions() throws {
                app.terminate()
                app.launchArguments = ["--ui-testing", "--ui-testing-touch-menu"]
                launchApp()
                let terminal = try requireTerminalInteractionTarget()
                typeTerminalText("clear\n", in: terminal)
                typeTerminalText("echo inline-selection\n", in: terminal)
                let point = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.025))
                point.press(forDuration: Self.longPressDuration)
                XCTAssertTrue(app.menuItems["Select"].waitForExistence(timeout: 4))
                XCTAssertFalse(app.menuItems["Paste"].exists)
                XCTAssertTrue(revealNativeMenuItem("Host Action").waitForExistence(timeout: 4))
                XCTAssertFalse(nativeMenuItem("Inspect Selection").exists)
                XCTAssertFalse(app.staticTexts["Paste"].exists)
                try assertSuppliedSystemMenuIsVisible()
                revealNativeMenuItem("Host Action").tap()
                XCTAssertEqual(terminal.value as? String, "host:none")
                point.press(forDuration: Self.longPressDuration)
                XCTAssertTrue(app.menuItems["Select"].waitForExistence(timeout: 4))
                app.menuItems["Select"].tap()
                XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 4))
                XCTAssertTrue(app.menuItems["Select All"].exists)
                XCTAssertFalse(app.menuItems["Paste"].exists)
                // A selection menu can page its trailing host items behind
                // UIKit's overflow arrow on a narrow phone.
                XCTAssertTrue(revealNativeMenuItem("Inspect Selection").waitForExistence(timeout: 4))
                XCTAssertFalse(nativeMenuItem("Host Action").exists)
                try assertSuppliedSystemMenuIsVisible()
                XCTAssertFalse(app.staticTexts["Paste"].exists)
                capture("inline-selection-host-menu")
                revealNativeMenuItem("Inspect Selection").tap()
                XCTAssertTrue((terminal.value as? String ?? "").hasPrefix("host:"))
                XCTAssertNotEqual(terminal.value as? String, "host:none")
            }

            private func assertSuppliedSystemMenuIsVisible() throws {
                let status = app.staticTexts["terminal.systemMenus"]
                let count = try XCTUnwrap(Int(status.value as? String ?? ""))
                log("system-menu-items", status.label)
                // UIKit can supply an empty or deferred AutoFill menu on simulators.
                // Concrete actions must survive both host override paths.
                if count > 0 {
                    XCTAssertTrue(revealNativeMenuItem("AutoFill").waitForExistence(timeout: 4), app.debugDescription)
                } else {
                    let attachment = XCTAttachment(
                        string: "UIKit supplied no concrete AutoFill actions: \(status.label)",
                    )
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }

            private func revealNativeMenuItem(_ title: String) -> XCUIElement {
                // UIKit uses an expanded menu on newer systems and pages on
                // older ones. Navigate its controls instead of assuming a layout.
                for direction in [["Next Page", "Forward"], ["Back"]] {
                    for _ in 0 ..< 4 {
                        let item = nativeMenuItem(title)
                        if item.exists, item.isHittable {
                            return item
                        }
                        guard let next = direction.map({ app.buttons[$0] })
                            .first(where: { $0.exists && $0.isHittable && $0.isEnabled })
                        else { break }
                        next.tap()
                    }
                }
                return nativeMenuItem(title)
            }

            func testInlineDoubleTripleTapAndSelectionDismissal() throws {
                app.terminate()
                app.launchArguments = ["--ui-testing"]
                launchApp()
                let terminal = try requireTerminalInteractionTarget()
                typeTerminalText("clear\n" + String(repeating: "echo alpha beta\n", count: 25), in: terminal)
                let wordPoint = pointerCell(in: terminal, column: 1)
                wordPoint.doubleTap()
                XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 4), app.debugDescription)
                app.menuItems["Copy"].tap()
                let word = try XCTUnwrap(copiedSelectionText(in: terminal, timeout: 2))
                XCTAssertFalse(word.contains(" "), word)
                XCTAssertFalse(word.contains("\n"), word)
                terminal.tap(withNumberOfTaps: 3, numberOfTouches: 1)
                XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 4), app.debugDescription)
                capture("inline-selection-row")
                app.menuItems["Copy"].tap()
                let row = try XCTUnwrap(copiedSelectionText(in: terminal, timeout: 2))
                XCTAssertTrue(row.contains("alpha beta"), row)
                wordPoint.doubleTap()
                XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 4))
                terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.9)).tap()
                XCTAssertFalse(app.menuItems["Copy"].exists)
                XCTAssertTrue(waitForKeyboardFocus(in: terminal, timeout: 2))
            }

            func testInlineSelectionScrollsAtBothEdgesAndCopiesHistory() throws {
                app.terminate()
                // The app writes the 45 commands itself: XCTest types a string
                // this long key by key whenever the keyboard is down, slower
                // than the test waits, and returns before it has all arrived.
                app.launchArguments = ["--ui-testing", "--ui-testing-history-fixture"]
                launchApp()
                let terminal = try requireTerminalInteractionTarget()
                waitForOutputLine("history-044 left middle right")
                let output = app.descendants(matching: .any)["terminal.output"].firstMatch
                func rows(in text: String) -> [Int] {
                    text.components(separatedBy: "history-").dropFirst().compactMap { Int($0.prefix(3)) }
                }
                for edge in [0.003, 0.997] {
                    let before = try XCTUnwrap(output.value as? String)
                    let firstBefore = try XCTUnwrap(rows(in: before).min())
                    terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).doubleTap()
                    XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 4))
                    let start = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
                    let end = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: edge))
                    start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 2)
                    XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 4))
                    let after = try XCTUnwrap(output.value as? String)
                    let firstAfter = try XCTUnwrap(rows(in: after).min())
                    if edge < 0.5 {
                        XCTAssertLessThan(firstAfter, firstBefore, after)
                    } else {
                        XCTAssertGreaterThan(firstAfter, firstBefore, after)
                    }
                    capture(edge < 0.5 ? "inline-scroll-top" : "inline-scroll-bottom")
                    app.menuItems["Copy"].tap()
                    let copied = try XCTUnwrap(copiedSelectionText(in: terminal, timeout: 2))
                    let copiedRows = rows(in: copied)
                    if edge < 0.5 {
                        XCTAssertLessThan(try XCTUnwrap(copiedRows.min()), firstBefore, copied)
                    } else {
                        XCTAssertGreaterThan(try XCTUnwrap(copiedRows.max()), try XCTUnwrap(rows(in: before).max()), copied)
                    }
                }
            }

            private func nativeMenuItem(_ title: String) -> XCUIElement {
                let compact = app.menuItems[title]
                return compact.exists ? compact : app.buttons[title]
            }

        #endif

        func testTerminalUserOperations() throws {
            let terminal = try requireTerminalInteractionTarget()

            capture("01-launch")
            typeTerminalText("uname\n", in: terminal)
            let output = app.descendants(matching: .any)["terminal.output"].firstMatch
            XCTAssertTrue(output.waitForExistence(timeout: 4))
            let expectedReturnOutput = "Darwin ghostty-sandbox host-managed"
            let outputExpectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value CONTAINS %@", expectedReturnOutput),
                object: output,
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [outputExpectation], timeout: 4),
                .completed,
            )
            let viewport = try XCTUnwrap(output.value as? String)
            XCTAssertEqual(viewport.nonOverlappingCount(of: expectedReturnOutput), 1)
            capture("02-single-line-input")

            typeTerminalText("echo first line\n", in: terminal)
            typeTerminalText("echo second line\n", in: terminal)
            capture("03-multiple-lines")

            typeTerminalText("中文键盘测试，标点和全角字符。\n", in: terminal)
            capture("04-chinese-input")

            typeTerminalText("日本語キーボードテスト、かなと漢字。\n", in: terminal)
            capture("05-japanese-input")

            typeTerminalText("Mixed input: English 中文 日本語 123\n", in: terminal)
            capture("06-multilingual-input")

            tapTerminal(in: terminal)
            capture("07-tap-dismiss-keyboard")
            tapTerminal(in: terminal)
            capture("08-tap-refocus")

            typeTerminalText("help\n", in: terminal)
            capture("09-help-output")

            terminal.swipeUp()
            capture("10-swipe-up")
            terminal.swipeDown()
            capture("11-swipe-down")

            #if targetEnvironment(macCatalyst)
                app.typeKey("=", modifierFlags: .command)
            #else
                terminal.pinch(withScale: 1.25, velocity: 1.0)
            #endif
            capture("12-zoom-in")
            // Use the keyboard zoom-out path on iOS because XCTest's second
            // pinch in one test session can report an invalid coordinate.
            app.typeKey("-", modifierFlags: .command)
            capture("13-zoom-out")

            typeTerminalText("clear\n", in: terminal)
            capture("14-clear-command")

            let pointerSelectionCommand: String
            #if targetEnvironment(macCatalyst)
                pointerSelectionCommand = "echo \(catalystPointerSelectionPrefix)\(expectedPointerSelection)\n"
            #else
                pointerSelectionCommand = isIPad
                    ? "echo \(iPadPointerSelectionPrefix)\(expectedPointerSelection)\n"
                    : "echo \(expectedPointerSelection)\n"
            #endif
            typeTerminalText(pointerSelectionCommand, in: terminal)
            #if targetEnvironment(macCatalyst)
                dragPointerSelection(in: terminal)
                capture("15-pointer-selection-catalyst")
                openCopyMenuAndCopySelection(in: terminal, screenshotName: "16-pointer-copy-menu-catalyst")
                longPressTerminal(in: terminal)
                capture("17-long-press-catalyst")
            #else
                if isIPad {
                    longPressTerminal(in: terminal, offset: CGVector(dx: 0.35, dy: 0.18))
                    if app.launchArguments.contains("--no-inline-selection") {
                        XCTAssertFalse(app.menuItems["Select"].waitForExistence(timeout: 1))
                    } else {
                        XCTAssertTrue(app.menuItems["Select"].waitForExistence(timeout: 4))
                        tapTerminal(in: terminal)
                        XCTAssertTrue(app.menuItems["Select"].waitForNonExistence(timeout: 4))
                    }

                    dismissTerminalKeyboard(in: terminal)
                    capture("16-ipad-keyboard-hidden-before-pointer")
                    let rightClick = dragIPadPointerSelection(in: terminal)
                    capture("17-ipad-pointer-selection")
                    openCopyMenuAndCopySelection(
                        in: terminal,
                        screenshotName: "18-ipad-pointer-copy-menu",
                        rightClickCoordinate: rightClick,
                    )
                } else {
                    longPressTerminal(in: terminal, offset: CGVector(dx: 0.35, dy: 0.18))
                    if app.launchArguments.contains("--no-inline-selection") {
                        XCTAssertFalse(app.menuItems["Select"].waitForExistence(timeout: 1))
                    } else {
                        XCTAssertTrue(app.menuItems["Select"].waitForExistence(timeout: 4))
                    }
                    capture("15-long-press-selection")
                }
            #endif

            #if !targetEnvironment(macCatalyst)
                if isIPad {
                    tapTerminal(in: terminal)
                    tapAccessoryButton("Tab", screenshotName: "16-accessory-tab")
                    tapAccessoryButton("Escape", screenshotName: "17-accessory-esc")
                    tapAccessoryButton("Right Arrow", screenshotName: "18-accessory-right")
                }
            #endif

            #if targetEnvironment(macCatalyst)
                openThemeMenuAndSelectPopularTheme()
                capture("19-theme-menu-selection")
            #else
                if isIPad {
                    openThemeMenuAndSelectPopularTheme()
                    capture("19-theme-menu-selection")
                }
            #endif
        }

        private func installSystemAlertHandler() {
            addUIInterruptionMonitor(withDescription: "System alert") { alert in
                guard alert.elementType == .alert || alert.elementType == .sheet else { return false }
                let preferredButtons = [
                    "OK", "Ok", "好", "确定", "允许", "Allow", "继续", "Continue",
                    "关闭", "Close", "Dismiss",
                ]
                for title in preferredButtons {
                    let button = alert.buttons[title].firstMatch
                    if button.exists {
                        self.activateInterruptionButton(button)
                        return true
                    }
                }

                return false
            }
        }

        private func activateInterruptionButton(_ button: XCUIElement) {
            #if targetEnvironment(macCatalyst)
                button.click()
            #else
                button.tap()
            #endif
        }

        private func requireTerminalInteractionTarget() throws -> XCUIElement {
            let terminal = app.descendants(matching: .any)["terminal.surface"].firstMatch
            if terminal.waitForExistence(timeout: 4), terminal.isHittable {
                return terminal
            }

            let window = app.windows.firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 8))
            XCTAssertTrue(window.isHittable)
            return window
        }

        private func tapTerminal(in element: XCUIElement) {
            let coordinate = element.coordinate(withNormalizedOffset: terminalInteractionOffset)
            #if targetEnvironment(macCatalyst)
                coordinate.click()
            #else
                if isIPad {
                    coordinate.tap()
                } else {
                    coordinate.press(forDuration: 0.01)
                }
            #endif
        }

        private func typeTerminalText(_ text: String, in element: XCUIElement) {
            #if targetEnvironment(macCatalyst)
                element.coordinate(withNormalizedOffset: terminalInteractionOffset).click()
                app.typeText(text)
            #else
                if !isIPad, !prepareTerminalForTyping(element) {
                    return
                }
                element.typeText(text)
            #endif
        }

        #if !targetEnvironment(macCatalyst)
            private func prepareTerminalForTyping(_ element: XCUIElement) -> Bool {
                if waitForKeyboardFocus(in: element, timeout: 0.5) {
                    return true
                }

                for _ in 0 ..< 2 {
                    tapTerminal(in: element)
                    if waitForKeyboardFocus(in: element, timeout: 2) {
                        return true
                    }
                }
                XCTFail("Terminal did not acquire keyboard focus before typing")
                return false
            }

            private func waitForKeyboardFocus(
                in element: XCUIElement,
                timeout: TimeInterval,
            ) -> Bool {
                let predicate = NSPredicate(format: "hasKeyboardFocus == true")
                if predicate.evaluate(with: element) {
                    return true
                }
                let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
                return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
            }
        #endif

        private func longPressTerminal(in element: XCUIElement, offset: CGVector? = nil) {
            element.coordinate(withNormalizedOffset: offset ?? terminalInteractionOffset).press(forDuration: Self.longPressDuration)
        }

        #if targetEnvironment(macCatalyst)
            private func dragPointerSelection(in element: XCUIElement) {
                let start = pointerCell(in: element, column: catalystPointerSelectionPrefix.count, fraction: 0)
                let end = pointerCell(in: element, column: catalystPointerSelectionPrefix.count + expectedPointerSelection.count + 1)
                start.press(forDuration: 0.3, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
            }
        #else
            private var isIPad: Bool {
                UIDevice.current.userInterfaceIdiom == .pad
            }

            /// Returns the right-click coordinate for the follow-up copy menu.
            ///
            /// The drag's own click makes the terminal first responder, which
            /// summons the software keyboard and shrinks the terminal mid-drag.
            /// A normalized offset resolved *after* that (the right click) would
            /// use the post-keyboard frame and land on a different row than the
            /// selection. Snapshot the frame once and convert every point to a
            /// screen-absolute coordinate so all events target the same spot —
            /// the text itself does not move when the view shrinks.
            private func dragIPadPointerSelection(in element: XCUIElement) -> XCUICoordinate {
                let start = pointerCell(in: element, column: iPadPointerSelectionPrefix.count, fraction: 0.25)
                // Finish in the empty cells after the text so pointer interpolation
                // cannot stop just before the last character.
                let end = pointerCell(in: element, column: iPadPointerSelectionPrefix.count + expectedPointerSelection.count + 1)
                let rightClick = pointerCell(in: element, column: iPadPointerSelectionPrefix.count + expectedPointerSelection.count / 2)
                start.click(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
                return rightClick
            }

            /// The fixture's first responder raises the keyboard, but on a
            /// loaded runner it can arrive late or not at all. On an iPad the
            /// simulator can start with only the accessory bar up, as if a
            /// hardware keyboard were attached, until XCTest first types; a
            /// tap cannot fix that, since it toggles the focused terminal's
            /// keyboard away. So: a typed space and its deletion while the
            /// terminal is focused (the shell line ends unchanged), a tap only
            /// while it is not. That typing can replace the pasteboard, so call
            /// this before a copy, never between a copy and its paste.
            private func requireSoftwareKeyboard(in terminal: XCUIElement) {
                let hittable = NSPredicate(format: "isHittable == true")
                for attempt in 0 ..< 3 {
                    let shown = XCTNSPredicateExpectation(predicate: hittable, object: app.keys["c"])
                    if XCTWaiter.wait(for: [shown], timeout: 4) == .completed {
                        return
                    }
                    guard attempt < 2 else { break }
                    if app.buttons["Command"].isHittable {
                        terminal.typeText(" " + XCUIKeyboardKey.delete.rawValue)
                    } else {
                        tapTerminal(in: terminal)
                    }
                }
                XCTFail("Software keyboard never appeared")
            }

            private func tapSoftwareKeys(_ text: String) {
                for character in text {
                    let key = String(character)
                    // iPad's full keyboard labels Space with a literal space.
                    let element = key == " " && app.keys["space"].exists ? app.keys["space"] : app.keys[key]
                    XCTAssertTrue(element.waitForExistence(timeout: 4))
                    element.tap()
                }
            }

            private func dismissTerminalKeyboard(in element: XCUIElement) {
                // Hardware input can retain focus while the software keyboard is hidden.
                guard app.keys["q"].exists, app.keys["q"].isHittable else { return }
                let unfocused = NSPredicate(format: "hasKeyboardFocus == false")
                tapTerminal(in: element)
                let hidden = XCTNSPredicateExpectation(predicate: unfocused, object: element)
                XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 4), .completed)
            }
        #endif

        private func pointerCell(in element: XCUIElement, column: Int, fraction: CGFloat = 0.5) -> XCUICoordinate {
            let geometry = app.staticTexts["terminal.grid"]
            XCTAssertTrue(geometry.waitForExistence(timeout: 4))
            let value = geometry.value as? String ?? ""
            let numbers = value.split(whereSeparator: { !$0.isNumber && $0 != "." }).compactMap { Double($0) }
            guard numbers.count == 3 else {
                XCTFail("Missing cell geometry: \(value)")
                return element.coordinate(withNormalizedOffset: .zero)
            }
            let offset = CGVector(
                dx: numbers[2] + (CGFloat(column) + fraction) * numbers[0],
                dy: numbers[2] + 1.5 * numbers[1],
            )
            #if targetEnvironment(macCatalyst)
                return element.coordinate(withNormalizedOffset: .zero).withOffset(offset)
            #else
                let frame = element.frame
                return app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                    dx: frame.minX + offset.dx, dy: frame.minY + offset.dy,
                ))
            #endif
        }

        private func openCopyMenuAndCopySelection(
            in element: XCUIElement,
            screenshotName: String,
            rightClickCoordinate: XCUICoordinate? = nil,
        ) {
            UIPasteboard.general.string = nil
            let coordinate: XCUICoordinate
            if let rightClickCoordinate {
                log("pointer-copy-menu-coordinate", "screen-absolute right click from drag snapshot")
                coordinate = rightClickCoordinate
            } else {
                #if targetEnvironment(macCatalyst)
                    coordinate = pointerCell(in: element, column: catalystPointerSelectionPrefix.count + expectedPointerSelection.count / 2)
                #else
                    coordinate = pointerCell(in: element, column: iPadPointerSelectionPrefix.count + expectedPointerSelection.count / 2)
                #endif
            }
            coordinate.rightClick()
            let copy = copyMenuItem()
            if !copy.waitForExistence(timeout: 3) {
                capture("\(screenshotName)-missing")
                XCTFail(
                    "Copy menu item not found after pointer selection right click. Hierarchy: \(app.debugDescription)",
                )
                return
            }
            capture(screenshotName)
            activateCopyMenuItem(copy)
            let actual = copiedSelectionText(in: element, timeout: 2)
            log("pointer-selection-pasteboard", actual ?? "<nil>")
            XCTAssertEqual(actual, expectedPointerSelection)
        }

        private func activateCopyMenuItem(_ copy: XCUIElement) {
            #if targetEnvironment(macCatalyst)
                copy.click()
            #else
                copy.tap()
            #endif
        }

        private func copyMenuItem() -> XCUIElement {
            #if targetEnvironment(macCatalyst)
                app.menuItems["Copy"].firstMatch
            #else
                app.buttons["Copy"].firstMatch
            #endif
        }

        private func copiedSelectionText(in element: XCUIElement, timeout: TimeInterval) -> String? {
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                if let string = copiedSelectionTextSnapshot(in: element, timeout: 0.25), !string.isEmpty {
                    return string
                }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            } while Date() < deadline
            return nil
        }

        private func copiedSelectionTextSnapshot(in element: XCUIElement, timeout: TimeInterval) -> String? {
            #if !targetEnvironment(macCatalyst)
                return element.value as? String
            #else
                _ = timeout
                return UIPasteboard.general.string
            #endif
        }

        private func log(_ name: String, _ value: String) {
            let attachment = XCTAttachment(string: value)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        #if targetEnvironment(macCatalyst)
            private var isIPad: Bool {
                false
            }
        #endif

        private var terminalInteractionOffset: CGVector {
            CGVector(dx: 0.5, dy: 0.55)
        }

        private func tapAccessoryButton(_ label: String, screenshotName: String) {
            dismissKeyboardOnboardingIfVisible()
            let button = app.buttons[label]
            guard button.waitForExistence(timeout: 2), button.isHittable else {
                capture("\(screenshotName)-not-visible")
                return
            }
            button.tap()
            capture(screenshotName)
        }

        private func dismissKeyboardOnboardingIfVisible() {
            let continueButton = app.buttons["Continue"].firstMatch
            guard continueButton.waitForExistence(timeout: 1), continueButton.isHittable else {
                return
            }
            #if targetEnvironment(macCatalyst)
                continueButton.click()
            #else
                continueButton.tap()
            #endif
        }

        private func openThemeMenuAndSelectPopularTheme() {
            let themeButton = app.buttons["terminal.themeButton"].firstMatch
            guard themeButton.waitForExistence(timeout: 2), themeButton.isHittable else {
                capture("theme-button-not-visible")
                return
            }
            themeButton.tap()
            capture("theme-menu-open")

            let popular = app.buttons["Popular"].firstMatch
            if popular.waitForExistence(timeout: 1), popular.isHittable {
                popular.tap()
                capture("theme-menu-popular")
            }

            let dracula = app.buttons["Dracula"].firstMatch
            if dracula.waitForExistence(timeout: 2), dracula.isHittable {
                dracula.tap()
            } else {
                capture("theme-dracula-not-visible")
                dismissOpenMenu()
            }
        }

        private func dismissOpenMenu() {
            #if targetEnvironment(macCatalyst)
                app.typeKey(.escape, modifierFlags: [])
            #else
                let window = app.windows.firstMatch
                guard window.exists else { return }
                window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
            #endif
        }

        private func capture(_ name: String) {
            guard let app else { return }
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        private var expectedPointerSelection: String {
            "selection anchor"
        }

        private var iPadPointerSelectionPrefix: String {
            // iPadOS/XCTest clamps the indirect pointer drag start a couple of
            // cells inside the view edge. The prefix keeps the single fixed drag
            // selecting the same expected terminal text without retries.
            "xx"
        }

        #if targetEnvironment(macCatalyst)
            private var catalystPointerSelectionPrefix: String {
                // Mac Catalyst clamps the left-edge pointer drag inside the first
                // text cell on GitHub runners. The prefix keeps the copied text
                // anchored to the same expected selection.
                "x"
            }
        #endif
    }

    private extension String {
        func nonOverlappingCount(of needle: String) -> Int {
            guard !needle.isEmpty else { return 0 }
            var count = 0
            var searchStart = startIndex
            while searchStart < endIndex,
                  let range = range(of: needle, range: searchStart ..< endIndex)
            {
                count += 1
                searchStart = range.upperBound
            }
            return count
        }
    }
#endif
