//
//  TerminalTextInputHandler@UIKit.swift
//  libghostty-spm
//

#if canImport(UIKit)
    import GhosttyKit
    import UIKit

    @MainActor
    final class TerminalTextInputHandler {
        private weak var view: UITerminalView?
        private var markedTextState = TerminalMarkedTextState()

        var hasMarkedText: Bool {
            markedTextState.hasMarkedText
        }

        var documentLength: Int {
            markedTextState.documentLength
        }

        init(view: UITerminalView) {
            self.view = view
        }

        // MARK: - Text Input

        func insertText(_ text: String) {
            guard let view else { return }
            let shouldNotifySelectionChange = shouldNotifySelectionChange

            TerminalDebugLog.log(
                .input,
                "insertText text=\(TerminalDebugLog.describe(text)) marked=\(hasMarkedText)"
            )

            view.inputDelegate?.textWillChange(view)
            if shouldNotifySelectionChange {
                view.inputDelegate?.selectionWillChange(view)
            }

            markedTextState.clear()
            view.surface?.preedit("")
            view.surface?.sendText(text)

            if shouldNotifySelectionChange {
                view.inputDelegate?.selectionDidChange(view)
            }
            view.inputDelegate?.textDidChange(view)
        }

        func setMarkedText(_ text: String?, selectedRange: NSRange) {
            guard let view else { return }

            TerminalDebugLog.log(
                .ime,
                "setMarkedText text=\(TerminalDebugLog.describe(text)) selected=\(TerminalDebugLog.describe(selectedRange))"
            )

            view.inputDelegate?.textWillChange(view)
            view.inputDelegate?.selectionWillChange(view)

            markedTextState.setMarkedText(text, selectedRange: selectedRange)

            if let text = markedTextState.text, !text.isEmpty {
                view.surface?.preedit(text)
            } else {
                view.surface?.preedit("")
            }

            view.inputDelegate?.selectionDidChange(view)
            view.inputDelegate?.textDidChange(view)
        }

        func unmarkText() {
            guard let view else { return }
            let shouldNotifySelectionChange = shouldNotifySelectionChange
            let committedText = markedTextState.text

            TerminalDebugLog.log(
                .ime,
                "unmarkText committed=\(TerminalDebugLog.describe(committedText))"
            )

            view.inputDelegate?.textWillChange(view)
            if shouldNotifySelectionChange {
                view.inputDelegate?.selectionWillChange(view)
            }

            markedTextState.clear()
            if let committedText, !committedText.isEmpty {
                view.surface?.sendText(committedText)
            }
            view.surface?.preedit("")

            if shouldNotifySelectionChange {
                view.inputDelegate?.selectionDidChange(view)
            }
            view.inputDelegate?.textDidChange(view)
        }

        func markedTextRange() -> TerminalTextRange? {
            guard markedTextState.hasMarkedText else { return nil }
            return TerminalTextRange(
                location: markedTextState.markedRange.location,
                length: markedTextState.markedRange.length
            )
        }

        func selectedTextRange() -> TerminalTextRange {
            TerminalTextRange(
                location: markedTextState.selectedRange.location,
                length: markedTextState.selectedRange.length
            )
        }

        func setSelectedTextRange(_ range: UITextRange?) {
            let updatedRange = if let range = range as? TerminalTextRange {
                NSRange(
                    location: range.location,
                    length: range.length
                )
            } else {
                NSRange(location: 0, length: 0)
            }
            let clampedRange = clampedSelectedRange(updatedRange)
            guard markedTextState.selectedRange != clampedRange else { return }
            TerminalDebugLog.log(
                .ime,
                "setSelectedTextRange range=\(TerminalDebugLog.describe(clampedRange))"
            )
            notifySelectionWillChange()
            markedTextState.setMarkedText(markedTextState.text, selectedRange: clampedRange)
            notifySelectionDidChange()
        }

        func text(in range: TerminalTextRange) -> String? {
            markedTextState.text(in: NSRange(
                location: range.location,
                length: range.length
            ))
        }

        func deleteBackwardInMarkedText() -> Bool {
            guard let view else { return false }
            guard markedTextState.hasMarkedText else { return false }
            let shouldNotifySelectionChange = shouldNotifySelectionChange
            TerminalDebugLog.log(
                .ime,
                "deleteBackwardInMarkedText selected=\(TerminalDebugLog.describe(markedTextState.selectedRange))"
            )
            view.inputDelegate?.textWillChange(view)
            if shouldNotifySelectionChange {
                view.inputDelegate?.selectionWillChange(view)
            }

            _ = markedTextState.deleteBackward()
            view.surface?.preedit(markedTextState.text ?? "")

            if shouldNotifySelectionChange {
                view.inputDelegate?.selectionDidChange(view)
            }
            view.inputDelegate?.textDidChange(view)
            return true
        }

        func notifyGeometryDidChange(reason: String) {
            guard let view else { return }
            TerminalDebugLog.log(
                .ime,
                "notifyGeometryDidChange reason=\(reason) selected=\(TerminalDebugLog.describe(markedTextState.selectedRange)) documentLength=\(markedTextState.documentLength) marked=\(hasMarkedText)"
            )
            view.inputDelegate?.selectionWillChange(view)
            view.inputDelegate?.selectionDidChange(view)
            if view.isFirstResponder {
                view.reloadInputViews()
            }
        }

        private var shouldNotifySelectionChange: Bool {
            hasMarkedText
                || markedTextState.selectedRange.location != 0
                || markedTextState.selectedRange.length != 0
        }

        private func clampedSelectedRange(_ range: NSRange) -> NSRange {
            let length = markedTextState.documentLength
            let location = min(max(range.location, 0), length)
            let end = min(max(range.location + range.length, location), length)
            return NSRange(location: location, length: end - location)
        }

        private func notifySelectionWillChange() {
            if let view {
                view.inputDelegate?.selectionWillChange(view)
            }
        }

        private func notifySelectionDidChange() {
            if let view {
                view.inputDelegate?.selectionDidChange(view)
            }
        }
    }
#endif
