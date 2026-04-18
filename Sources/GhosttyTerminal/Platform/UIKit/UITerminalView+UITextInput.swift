//
//  UITerminalView+UITextInput.swift
//  libghostty-spm
//

#if canImport(UIKit)
    import GhosttyKit
    import UIKit

    extension UITerminalView: UITextInput, UITextInputTraits {
        // MARK: - UITextInputTraits

        public var autocorrectionType: UITextAutocorrectionType {
            get { .no }
            set {}
        }

        public var autocapitalizationType: UITextAutocapitalizationType {
            get { .none }
            set {}
        }

        public var smartQuotesType: UITextSmartQuotesType {
            get { .no }
            set {}
        }

        public var smartDashesType: UITextSmartDashesType {
            get { .no }
            set {}
        }

        public var smartInsertDeleteType: UITextSmartInsertDeleteType {
            get { .no }
            set {}
        }

        public var spellCheckingType: UITextSpellCheckingType {
            get { .no }
            set {}
        }

        public var keyboardType: UIKeyboardType {
            get { .default }
            set {}
        }

        // MARK: - UIKeyInput

        public func insertText(_ text: String) {
            guard !hardwareKeyHandled else {
                TerminalDebugLog.log(
                    .input,
                    "insertText suppressed text=\(TerminalDebugLog.describe(text))"
                )
                hardwareKeyHandled = false
                return
            }

            #if !targetEnvironment(macCatalyst)
                if inputHandler.hasMarkedText {
                    inputHandler.insertText(text)
                    return
                }

                if stickyModifiers.hasActiveModifiers {
                    _ = handleStickyTextInput(text)
                    return
                }
            #endif

            inputHandler.insertText(text)
        }

        public func deleteBackward() {
            if inputHandler.deleteBackwardInMarkedText() {
                TerminalDebugLog.log(.input, "deleteBackward handled by marked text")
                hardwareKeyHandled = false
                return
            }

            guard !hardwareKeyHandled else {
                TerminalDebugLog.log(.input, "deleteBackward suppressed")
                hardwareKeyHandled = false
                return
            }

            let usage = UInt16(UIKeyboardHIDUsage.keyboardDeleteOrBackspace.rawValue)

            #if !targetEnvironment(macCatalyst)
                if stickyModifiers.hasActiveModifiers {
                    let mods = stickyModifiers.consumeForNextKey()
                    sendSyntheticKey(usage: usage, additionalMods: mods)
                    return
                }
            #endif

            let delivery = TerminalHardwareKeyRouter.routeUIKit(
                usage: usage,
                backend: configuration.backend
            )
            if case let .data(sequence) = delivery,
               case let .inMemory(session) = configuration.backend
            {
                session.sendInput(sequence)
                return
            }

            var keyEvent = ghostty_input_key_s()
            keyEvent.action = GHOSTTY_ACTION_PRESS
            keyEvent.mods = ghostty_input_mods_e(rawValue: 0)
            keyEvent.keycode = TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(
                usage: usage
            )
            keyEvent.composing = false

            let delete = "\u{7F}"
            delete.withCString { ptr in
                keyEvent.text = ptr
                surface?.sendKeyEvent(keyEvent)
            }
        }

        // MARK: - UITextInput Marked Text

        public func setMarkedText(
            _ markedText: String?,
            selectedRange: NSRange
        ) {
            inputHandler.setMarkedText(markedText, selectedRange: selectedRange)
        }

        public func unmarkText() {
            inputHandler.unmarkText(applyingStickyModifiers: false)
        }

        public var markedTextRange: UITextRange? {
            inputHandler.markedTextRange()
        }

        public var markedTextStyle: [NSAttributedString.Key: Any]? {
            get { nil }
            set {}
        }

        // MARK: - UITextInput Selection

        public var selectedTextRange: UITextRange? {
            get { inputHandler.selectedTextRange() }
            set { inputHandler.setSelectedTextRange(newValue) }
        }

        // MARK: - UITextInput Positions

        public var beginningOfDocument: UITextPosition {
            TerminalTextPosition(0)
        }

        public var endOfDocument: UITextPosition {
            TerminalTextPosition(inputHandler.documentLength)
        }

        public func textRange(
            from fromPosition: UITextPosition,
            to toPosition: UITextPosition
        ) -> UITextRange? {
            guard
                let from = fromPosition as? TerminalTextPosition,
                let to = toPosition as? TerminalTextPosition
            else { return nil }
            return TerminalTextRange(start: from, end: to)
        }

        public func position(
            from position: UITextPosition,
            offset: Int
        ) -> UITextPosition? {
            guard let pos = position as? TerminalTextPosition else { return nil }
            let newIndex = pos.index + offset
            guard newIndex >= 0, newIndex <= inputHandler.documentLength else { return nil }
            return TerminalTextPosition(newIndex)
        }

        public func position(
            from position: UITextPosition,
            in _: UITextLayoutDirection,
            offset: Int
        ) -> UITextPosition? {
            self.position(from: position, offset: offset)
        }

        public func compare(
            _ position: UITextPosition,
            to other: UITextPosition
        ) -> ComparisonResult {
            guard
                let lhs = position as? TerminalTextPosition,
                let rhs = other as? TerminalTextPosition
            else { return .orderedSame }

            if lhs.index < rhs.index { return .orderedAscending }
            if lhs.index > rhs.index { return .orderedDescending }
            return .orderedSame
        }

        public func offset(
            from: UITextPosition,
            to toPosition: UITextPosition
        ) -> Int {
            guard
                let f = from as? TerminalTextPosition,
                let t = toPosition as? TerminalTextPosition
            else { return 0 }
            return t.index - f.index
        }

        // MARK: - UITextInput Text

        public func text(in range: UITextRange) -> String? {
            guard let range = range as? TerminalTextRange else { return nil }
            return inputHandler.text(in: range)
        }

        public func replace(_: UITextRange, withText text: String) {
            #if !targetEnvironment(macCatalyst)
                if inputHandler.hasMarkedText {
                    inputHandler.insertText(text)
                    return
                }

                if stickyModifiers.hasActiveModifiers {
                    _ = handleStickyTextInput(text)
                    return
                }
            #endif

            inputHandler.insertText(text)
        }

        // MARK: - UITextInput Delegate

        public var inputDelegate: (any UITextInputDelegate)? {
            get { _inputDelegate }
            set { _inputDelegate = newValue }
        }

        // MARK: - UITextInput Tokenizer

        public var tokenizer: any UITextInputTokenizer {
            UITextInputStringTokenizer(textInput: self)
        }

        public var textInputView: UIView {
            self
        }

        // MARK: - UITextInput Geometry

        public func firstRect(for range: UITextRange) -> CGRect {
            if let range = range as? TerminalTextRange {
                return rectForRange(range)
            }
            return markedTextRect()
        }

        public func caretRect(for position: UITextPosition) -> CGRect {
            caretRectForPosition(position)
        }

        public func selectionRects(
            for _: UITextRange
        ) -> [UITextSelectionRect] {
            []
        }

        public func closestPosition(to point: CGPoint) -> UITextPosition? {
            TerminalTextPosition(textIndex(for: point))
        }

        public func closestPosition(
            to point: CGPoint,
            within _: UITextRange
        ) -> UITextPosition? {
            closestPosition(to: point)
        }

        public func characterRange(at point: CGPoint) -> UITextRange? {
            let index = textIndex(for: point)
            return TerminalTextRange(location: index, length: 0)
        }

        public func position(
            within range: UITextRange,
            farthestIn direction: UITextLayoutDirection
        ) -> UITextPosition? {
            switch direction {
            case .left, .up: return range.start
            case .right, .down: return range.end
            @unknown default: return range.start
            }
        }

        public func characterRange(
            byExtending position: UITextPosition,
            in _: UITextLayoutDirection
        ) -> UITextRange? {
            guard inputHandler.documentLength > 0,
                  let position = position as? TerminalTextPosition
            else {
                return TerminalTextRange(location: 0, length: 0)
            }

            let location = min(max(position.index, 0), inputHandler.documentLength - 1)
            return TerminalTextRange(location: location, length: 1)
        }

        public func baseWritingDirection(
            for _: UITextPosition,
            in _: UITextStorageDirection
        ) -> NSWritingDirection {
            .leftToRight
        }

        public func setBaseWritingDirection(
            _: NSWritingDirection,
            for _: UITextRange
        ) {}

        private func imeRect() -> CGRect {
            guard let surface else { return .zero }
            let point = surface.imePoint()
            return CGRect(
                x: point.x,
                y: point.y,
                width: point.width,
                height: point.height
            )
        }

        private func markedTextRect() -> CGRect {
            let baseRect = imeRect()
            guard
                inputHandler.documentLength > 0,
                let range = markedTextRange as? TerminalTextRange
            else {
                return baseRect
            }

            return rect(for: range, in: baseRect, fallbackWidth: baseRect.width)
        }

        private func rectForRange(_ range: TerminalTextRange) -> CGRect {
            rect(for: range, in: imeRect(), fallbackWidth: 2)
        }

        private func caretRectForPosition(_ position: UITextPosition) -> CGRect {
            let baseRect = imeRect()
            let cellWidth = compositionCellWidth(in: baseRect)
            guard inputHandler.documentLength > 0 else {
                let rect = CGRect(
                    x: baseRect.minX,
                    y: baseRect.minY,
                    width: cellWidth,
                    height: baseRect.height
                )
                TerminalDebugLog.log(
                    .ime,
                    "caretRect empty position base=\(NSCoder.string(for: baseRect)) rect=\(NSCoder.string(for: rect))"
                )
                return rect
            }

            guard let position = position as? TerminalTextPosition else {
                let rect = CGRect(
                    x: baseRect.maxX,
                    y: baseRect.minY,
                    width: cellWidth,
                    height: baseRect.height
                )
                TerminalDebugLog.log(
                    .ime,
                    "caretRect fallback base=\(NSCoder.string(for: baseRect)) rect=\(NSCoder.string(for: rect))"
                )
                return rect
            }

            let clampedIndex = min(max(position.index, 0), inputHandler.documentLength)
            let x = baseRect.minX + CGFloat(clampedIndex) * cellWidth
            let rect = CGRect(
                x: x,
                y: baseRect.minY,
                width: cellWidth,
                height: baseRect.height
            )
            TerminalDebugLog.log(
                .ime,
                "caretRect index=\(clampedIndex) base=\(NSCoder.string(for: baseRect)) cellWidth=\(String(format: "%.2f", cellWidth)) rect=\(NSCoder.string(for: rect))"
            )
            return rect
        }

        private func rect(
            for range: TerminalTextRange,
            in baseRect: CGRect,
            fallbackWidth: CGFloat
        ) -> CGRect {
            let documentLength = max(inputHandler.documentLength, 1)
            let cellWidth = compositionCellWidth(in: baseRect)
            let location = min(max(range.location, 0), documentLength)
            let length = max(range.length, 0)
            let x = baseRect.minX + CGFloat(location) * cellWidth
            let width = max(CGFloat(length) * cellWidth, fallbackWidth)
            return CGRect(
                x: x,
                y: baseRect.minY,
                width: width,
                height: baseRect.height
            )
        }

        private func compositionCellWidth(in baseRect: CGRect) -> CGFloat {
            if baseRect.width > 0 {
                return max(baseRect.width, 2)
            }

            guard let size = surface?.size() else { return 2 }
            let scale = resolvedDisplayScale()
            guard scale > 0 else { return CGFloat(max(size.cellWidthPixels, 2)) }
            return max(CGFloat(size.cellWidthPixels) / scale, 2)
        }

        private func textIndex(for point: CGPoint) -> Int {
            let baseRect = imeRect()
            guard inputHandler.documentLength > 0 else { return 0 }

            let cellWidth = compositionCellWidth(in: baseRect)
            guard cellWidth > 0 else { return 0 }

            let relativeX = point.x - baseRect.minX
            let rawIndex = Int((relativeX / cellWidth).rounded(.down))
            let index = min(max(rawIndex, 0), inputHandler.documentLength)
            TerminalDebugLog.log(
                .ime,
                "textIndex point=\(NSCoder.string(for: point)) base=\(NSCoder.string(for: baseRect)) cellWidth=\(String(format: "%.2f", cellWidth)) index=\(index)"
            )
            return index
        }
    }
#endif
