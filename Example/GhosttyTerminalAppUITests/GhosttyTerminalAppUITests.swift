import AppKit
import XCTest

final class GhosttyTerminalAppUITests: XCTestCase {
    private var app: XCUIApplication!
    private var systemAlertMonitor: NSObjectProtocol?

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Skip state restoration: a window restored at the minimum size moves
        // every normalized coordinate below onto a different terminal row.
        app.launchArguments = ["--ui-testing", "-ApplePersistenceIgnoreState", "YES"]
        systemAlertMonitor = installSystemAlertHandler()
        launchApp()
    }

    /// Pins the app to English so menu titles match on any host language.
    private func launchApp() {
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }

    override func tearDownWithError() throws {
        capture("final-state")
        app = nil
    }

    func testTerminalUserOperations() throws {
        let terminal = try requireTerminalInteractionTarget()

        capture("01-launch")
        clickTerminal(in: terminal)
        capture("02-focus")

        typeTerminalText("echo mac-single\n", in: terminal)
        capture("03-single-line-input")

        typeTerminalText("echo mac first line\n", in: terminal)
        typeTerminalText("echo mac second line\n", in: terminal)
        capture("04-multiple-lines")

        typeTerminalText("中文键盘测试，标点和全角字符。\n", in: terminal)
        capture("05-chinese-input")

        typeTerminalText("日本語キーボードテスト、かなと漢字。\n", in: terminal)
        capture("06-japanese-input")

        typeTerminalText("Mixed input: English 中文 日本語 123\n", in: terminal)
        capture("07-multilingual-input")

        terminal.swipeUp()
        capture("08-swipe-up")
        terminal.swipeDown()
        capture("09-swipe-down")

        app.typeKey("=", modifierFlags: .command)
        capture("10-keyboard-zoom-in")
        app.typeKey("-", modifierFlags: .command)
        capture("11-keyboard-zoom-out")

        typeTerminalText("clear\n", in: terminal)
        capture("12-clear-command")

        assertNoCopyMenuWithoutSelection(in: terminal)
        let anchor = "selection anchor"
        typeTerminalText("echo \(anchor)\n", in: terminal)
        waitForOutputLine(anchor)
        // After `clear` the command echo is row 0 and its output row 1.
        let grid = try XCTUnwrap(cellGeometry(), "terminal.grid reported no cell size")
        dragPointerSelection(
            from: grid.point(column: 0, row: 1, in: terminal, fraction: 0.25),
            to: grid.point(column: anchor.count - 1, row: 1, in: terminal, fraction: 0.75),
        )
        capture("13-pointer-selection")
        openCopyMenuAndCopySelection(
            at: grid.point(column: anchor.count / 2, row: 1, in: terminal),
            expected: anchor,
            screenshotName: "14-pointer-copy-menu",
        )
        longPressTerminal(in: terminal)
        capture("15-long-press")
    }

    // MARK: - Lifecycle and stress

    func testTypedCommandBurstProducesEveryOutputInOrder() throws {
        let terminal = try requireTerminalInteractionTarget()
        typeTerminalText("clear\n", in: terminal)
        let expected = (1 ... 12).map { String(format: "burst-%02d", $0) }
        typeTerminalText(expected.map { "echo \($0)\n" }.joined(), in: terminal)

        let viewport = waitForViewport("all burst outputs") { text in
            Self.isOrderedTail(Self.outputLines(of: text).filter { $0.hasPrefix("burst-") }, of: expected)
        }
        XCTAssertNotNil(viewport)
        capture("burst-output")
    }

    func testHideAndUnhideKeepsFocusAndTyping() throws {
        let terminal = try requireTerminalInteractionTarget()
        typeTerminalText("echo before-hide\n", in: terminal)
        waitForOutputLine("before-hide")

        for cycle in 1 ... 3 {
            app.typeKey("h", modifierFlags: .command)
            let hidden = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "isHittable == false"),
                object: terminal,
            )
            XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed, "App did not hide, cycle \(cycle)")
            app.activate()
            XCTAssertTrue(terminal.waitForHittable(timeout: 5), "Terminal did not come back, cycle \(cycle)")
            capture("unhidden-\(cycle)")
            XCTAssertTrue(Self.outputLines(of: viewportText()).contains("before-hide"))

            // No click: the terminal must still be first responder after unhide.
            app.typeText("echo after-unhide-\(cycle)\n")
            waitForOutputLine("after-unhide-\(cycle)")
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

        terminal.scroll(byDeltaX: 0, deltaY: 300)
        waitForViewport("viewport scrolled into history") { $0 != bottomText }
        capture("scrolled-into-history")

        app.typeText("echo after-scroll\n")
        waitForOutputLine("after-scroll")
        capture("scrolled-back-on-typing")
    }

    func testWindowResizeChangesGridAndKeepsTerminalUsable() throws {
        let terminal = try requireTerminalInteractionTarget()
        let original = try XCTUnwrap(terminalGridSize(in: terminal))
        let window = app.windows.firstMatch
        let originalWidth = window.frame.width

        // Widen first: a restored window can already sit at the minimum width.
        dragWindowRightEdge(window, by: 200)
        waitForFrameWidth(of: window) { $0 > originalWidth + 100 }
        let widened = try XCTUnwrap(terminalGridSize(in: terminal))
        XCTAssertGreaterThan(widened.columns, original.columns)
        capture("window-widened")

        dragWindowRightEdge(window, by: -200)
        waitForFrameWidth(of: window) { $0 < originalWidth + 20 }
        let restored = try XCTUnwrap(terminalGridSize(in: terminal))
        XCTAssertLessThan(restored.columns, widened.columns)
        typeTerminalText("echo after-resize\n", in: terminal)
        waitForOutputLine("after-resize")
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

    // MARK: - Lifecycle helpers

    private struct GridSize: Equatable {
        var columns: Int
        var rows: Int
    }

    private func viewportText() -> String {
        (app.descendants(matching: .any)["terminal.output"].firstMatch.value as? String) ?? ""
    }

    private static func outputLines(of viewport: String) -> [String] {
        viewport.components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    /// The viewport holds only the last screenful, so a long run of output
    /// shows its tail: `visible` must be a non-empty, in-order tail of
    /// `expected`.
    private static func isOrderedTail(_ visible: [String], of expected: [String]) -> Bool {
        !visible.isEmpty && Array(expected.suffix(visible.count)) == visible
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

    private func waitForOutputLine(_ line: String) {
        waitForViewport("output line \(line)") {
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

    private static func parseGridSize(_ viewport: String) -> GridSize? {
        for line in outputLines(of: viewport).reversed() where line.hasPrefix("columns: ") {
            let numbers = line.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard numbers.count >= 2 else { continue }
            return GridSize(columns: numbers[0], rows: numbers[1])
        }
        return nil
    }

    private func dragWindowRightEdge(_ window: XCUIElement, by dx: CGFloat) {
        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -1, dy: 0))
        edge.press(forDuration: 0.3, thenDragTo: edge.withOffset(CGVector(dx: dx, dy: 0)))
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

    private func clickTerminal(in element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).click()
    }

    private func installSystemAlertHandler() -> NSObjectProtocol {
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            // Typing CJK text makes XCTest switch input sources, and macOS
            // shows a small input-source HUD near the caret that AX reports
            // as an app-owned dialog. Left to XCTest's built-in handler, it
            // clicks through the HUD's InputSource button and dies on a
            // stale snapshot when the transient window vanishes mid-query.
            // Claim it handled — the HUD dismisses on its own and never
            // blocks the interaction.
            if alert.buttons["InputSource"].firstMatch.exists {
                return true
            }

            let preferredButtons = [
                "OK", "Ok", "好", "确定", "允许", "Allow", "继续", "Continue",
                "关闭", "Close", "Dismiss",
            ]
            for title in preferredButtons {
                let button = alert.buttons[title].firstMatch
                if button.exists {
                    button.click()
                    return true
                }
            }

            return false
        }
    }

    private func typeTerminalText(_ text: String, in element: XCUIElement) {
        clickTerminal(in: element)
        element.typeText(text)
    }

    private func longPressTerminal(in element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).press(forDuration: 0.7)
    }

    /// Cell size and padding in points, from the app's `terminal.grid`
    /// element (DEBUG, `--ui-testing`).
    private struct CellGeometry {
        var cell: CGSize
        var padding: CGFloat

        /// A point inside a cell: `fraction` across it, vertically centred.
        func point(
            column: Int,
            row: Int,
            in element: XCUIElement,
            fraction: CGFloat = 0.5,
        ) -> XCUICoordinate {
            element.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                dx: padding + (CGFloat(column) + fraction) * cell.width,
                dy: padding + (CGFloat(row) + 0.5) * cell.height,
            ))
        }
    }

    private func cellGeometry() -> CellGeometry? {
        let element = app.staticTexts["terminal.grid"]
        guard element.waitForExistence(timeout: 5) else { return nil }
        let value = element.value as? String ?? ""
        let numbers = value.split(whereSeparator: { !$0.isNumber && $0 != "." }).compactMap { Double($0) }
        guard numbers.count == 3, numbers[0] > 0, numbers[1] > 0 else { return nil }
        log("cell-geometry", value)
        return CellGeometry(
            cell: CGSize(width: numbers[0], height: numbers[1]),
            padding: numbers[2],
        )
    }

    /// Starts a quarter into the first cell and ends three quarters into the
    /// last, so both ends fall on the selected side of their cell's midpoint.
    private func dragPointerSelection(from start: XCUICoordinate, to end: XCUICoordinate) {
        log("pointer-selection-coordinates", "start=\(start.screenPoint) end=\(end.screenPoint)")
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    private func openCopyMenuAndCopySelection(
        at point: XCUICoordinate,
        expected: String,
        screenshotName: String,
    ) {
        NSPasteboard.general.clearContents()
        disableSystemAlertMonitorBeforeContextMenu()
        defer { reinstallSystemAlertMonitorAfterContextMenu() }
        point.rightClick()
        let copy = copyMenuItem()
        if !copy.waitForExistence(timeout: 3) {
            capture("\(screenshotName)-missing")
            XCTFail("Copy menu item not found after pointer selection right click. Hierarchy: \(app.debugDescription)")
            return
        }
        copy.click()
        capture(screenshotName)
        let actual = copiedPasteboardText(timeout: 2)
        log("pointer-selection-pasteboard", actual ?? "<nil>")
        XCTAssertEqual(actual, expected)
    }

    private func assertNoCopyMenuWithoutSelection(in element: XCUIElement) {
        disableSystemAlertMonitorBeforeContextMenu()
        defer { reinstallSystemAlertMonitorAfterContextMenu() }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.20, dy: 0.10)).rightClick()
        XCTAssertFalse(
            copyMenuItem().waitForExistence(timeout: 0.5),
            "Copy menu item appeared without an active terminal selection.",
        )
    }

    /// The monitor must stay away only while a context menu is open — a
    /// menu counts as an interrupting element and the handler would dismiss
    /// it. Every other interaction wants the monitor back, or XCTest's
    /// built-in interruption handling runs unguarded (see the input-source
    /// HUD note above).
    private func disableSystemAlertMonitorBeforeContextMenu() {
        if let systemAlertMonitor {
            removeUIInterruptionMonitor(systemAlertMonitor)
            self.systemAlertMonitor = nil
        }
    }

    private func reinstallSystemAlertMonitorAfterContextMenu() {
        guard systemAlertMonitor == nil else { return }
        systemAlertMonitor = installSystemAlertHandler()
    }

    private func copyMenuItem() -> XCUIElement {
        app.menuItems["Copy"].firstMatch
    }

    private func copiedPasteboardText(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let string = NSPasteboard.general.string(forType: .string) {
                return string
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return nil
    }

    private func log(_ name: String, _ value: String) {
        let attachment = XCTAttachment(string: value)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func capture(_ name: String) {
        guard let app else { return }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private extension XCUIElement {
    func waitForHittable(timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: self,
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
