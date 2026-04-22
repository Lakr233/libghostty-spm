//
//  AppTerminalView+NSTextInputClient.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit

    extension AppTerminalView: @preconcurrency NSTextInputClient {
        public func insertText(_ string: Any, replacementRange _: NSRange) {
            inputHandler?.inputMethodHandler?.insertText(string)
        }

        public func setMarkedText(
            _ string: Any,
            selectedRange: NSRange,
            replacementRange _: NSRange
        ) {
            inputHandler?.inputMethodHandler?.setMarkedText(
                string,
                selectedRange: selectedRange
            )
        }

        public func unmarkText() {
            inputHandler?.inputMethodHandler?.unmarkText()
        }

        public func selectedRange() -> NSRange {
            inputHandler?.inputMethodHandler?.currentSelectedRange()
                ?? NSRange(location: NSNotFound, length: 0)
        }

        public func markedRange() -> NSRange {
            inputHandler?.inputMethodHandler?.markedRange()
                ?? NSRange(location: NSNotFound, length: 0)
        }

        public func hasMarkedText() -> Bool {
            inputHandler?.inputMethodHandler?.hasMarkedText ?? false
        }

        public func attributedSubstring(
            forProposedRange range: NSRange,
            actualRange: NSRangePointer?
        ) -> NSAttributedString? {
            inputHandler?.inputMethodHandler?.attributedSubstring(
                forProposedRange: range,
                actualRange: actualRange
            )
        }

        public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
            []
        }

        public func firstRect(
            forCharacterRange _: NSRange,
            actualRange _: NSRangePointer?
        ) -> NSRect {
            guard let surface else { return .zero }

            let point = surface.imePoint()
            let viewRect = NSRect(
                x: point.x,
                y: bounds.height - point.y - point.height,
                width: point.width,
                height: point.height
            )

            guard let window else { return viewRect }
            let windowRect = convert(viewRect, to: nil)
            return window.convertToScreen(windowRect)
        }

        public func characterIndex(for _: NSPoint) -> Int {
            NSNotFound
        }
    }
#endif
