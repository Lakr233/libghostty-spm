import Foundation
import GhosttyKit

/// Dispatches C runtime callbacks to a ``TerminalViewDelegate``.
///
/// An instance of this class is passed as the `userdata` pointer in the
/// surface config so that Ghostty callbacks can route actions back to
/// the owning view.
@MainActor
final class TerminalSurfaceBridge {
    weak var delegate: (any TerminalViewDelegate)?

    init(delegate: (any TerminalViewDelegate)? = nil) {
        self.delegate = delegate
    }

    func handleAction(_ action: ghostty_action_s) {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            if let cStr = action.action.set_title.title {
                delegate?.terminalDidChangeTitle(String(cString: cStr))
            }

        case GHOSTTY_ACTION_CELL_SIZE:
            break

        case GHOSTTY_ACTION_RING_BELL:
            break

        default:
            break
        }
    }

    func handleClose(processAlive: Bool) {
        delegate?.terminalDidClose(processAlive: processAlive)
    }
}
