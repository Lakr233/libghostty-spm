import GhosttyKit

@MainActor
public protocol TerminalViewDelegate: AnyObject {
    func terminalDidChangeTitle(_ title: String)
    func terminalDidResize(_ size: TerminalSurfaceSize)
    func terminalDidResize(columns: Int, rows: Int)
    func terminalDidClose(processAlive: Bool)
}

public extension TerminalViewDelegate {
    func terminalDidChangeTitle(_: String) {}
    func terminalDidResize(_ size: TerminalSurfaceSize) {
        terminalDidResize(columns: Int(size.columns), rows: Int(size.rows))
    }

    func terminalDidResize(columns _: Int, rows _: Int) {}
    func terminalDidClose(processAlive _: Bool) {}
}
