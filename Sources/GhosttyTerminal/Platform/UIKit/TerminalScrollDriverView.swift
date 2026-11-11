//
//  TerminalScrollDriverView.swift
//  libghostty-spm
//

#if canImport(UIKit) && !targetEnvironment(macCatalyst)
    import UIKit

    /// A scroll view the terminal view borrows a gesture and its physics
    /// from, and nothing else: it draws nothing and takes no touches.
    final class TerminalScrollDriverView: UIScrollView {
        /// Whether a one-finger drag starting now is this view's. When it
        /// is not, its pan does not begin and the terminal view's own does.
        var shouldBeginPan: (() -> Bool)?

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === panGestureRecognizer, let shouldBeginPan, !shouldBeginPan() {
                return false
            }
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }

        /// Taps, long presses and the selection handles belong to the
        /// terminal view's own touches and recognizers.
        override func hitTest(_: CGPoint, with _: UIEvent?) -> UIView? {
            nil
        }
    }
#endif
