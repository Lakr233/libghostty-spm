@testable import GhosttyTerminal
import Testing

struct TerminalSurfaceOptionsTests {
    @Test
    func `envVars default to empty`() {
        #expect(TerminalSurfaceOptions().envVars.isEmpty)
    }

    @Test
    func `isEquivalent considers envVars`() {
        let base = TerminalSurfaceOptions(workingDirectory: "/tmp", envVars: ["A": "1"])
        #expect(base.isEquivalent(to: base))

        var changedValue = base
        changedValue.envVars = ["A": "2"]
        #expect(!base.isEquivalent(to: changedValue))

        var extraEntry = base
        extraEntry.envVars = ["A": "1", "B": "2"]
        #expect(!base.isEquivalent(to: extraEntry))
    }

    @Test
    func `command and waitAfterCommand default to nil`() {
        #expect(TerminalSurfaceOptions().command == nil)
        #expect(TerminalSurfaceOptions().waitAfterCommand == nil)
    }

    @Test
    func `isEquivalent considers command and waitAfterCommand`() {
        let base = TerminalSurfaceOptions(command: "top", waitAfterCommand: true)
        #expect(base.isEquivalent(to: base))

        var changedCommand = base
        changedCommand.command = "htop"
        #expect(!base.isEquivalent(to: changedCommand))

        var changedWait = base
        changedWait.waitAfterCommand = false
        #expect(!base.isEquivalent(to: changedWait))
    }
}
