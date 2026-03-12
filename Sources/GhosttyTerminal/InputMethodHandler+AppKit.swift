#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import GhosttyKit

    @MainActor
    final class InputMethodHandler: NSObject {
        private weak var view: AppKitTerminalView?
        private var markedText: NSAttributedString?
        private var accumulatedTexts: [String]?

        var hasMarkedText: Bool {
            guard let markedText else { return false }
            return markedText.length > 0
        }

        init(view: AppKitTerminalView) {
            self.view = view
            super.init()
        }

        func startCollectingText() {
            accumulatedTexts = []
        }

        func finishCollectingText() -> [String]? {
            defer { accumulatedTexts = nil }
            guard let texts = accumulatedTexts, !texts.isEmpty else { return nil }
            return texts
        }

        // MARK: - Text Input

        func insertText(_ string: Any) {
            let text: String
            if let attrStr = string as? NSAttributedString {
                text = attrStr.string
            } else if let str = string as? String {
                text = str
            } else {
                return
            }

            markedText = nil

            if accumulatedTexts != nil {
                accumulatedTexts?.append(text)
            } else {
                view?.surface?.sendText(text)
            }
        }

        func setMarkedText(
            _ string: Any,
            selectedRange _: NSRange
        ) {
            let text: String
            if let attrStr = string as? NSAttributedString {
                markedText = attrStr
                text = attrStr.string
            } else if let str = string as? String {
                markedText = NSAttributedString(string: str)
                text = str
            } else {
                return
            }

            if text.isEmpty {
                view?.surface?.preedit("")
            } else {
                view?.surface?.preedit(text)
            }
        }

        func unmarkText() {
            markedText = nil
            view?.surface?.preedit("")
        }

        func markedRange() -> NSRange {
            guard let marked = markedText, marked.length > 0 else {
                return NSRange(location: NSNotFound, length: 0)
            }
            return NSRange(location: 0, length: marked.length)
        }
    }
#endif
