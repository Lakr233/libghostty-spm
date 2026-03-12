import GhosttyKit

@MainActor
public protocol TerminalViewDelegate: AnyObject {
    func terminalDidChangeTitle(_ title: String)
    func terminalDidResize(columns: Int, rows: Int)
    func terminalDidClose(processAlive: Bool)
}

public extension TerminalViewDelegate {
    func terminalDidChangeTitle(_: String) {}
    func terminalDidResize(columns _: Int, rows _: Int) {}
    func terminalDidClose(processAlive _: Bool) {}
}
