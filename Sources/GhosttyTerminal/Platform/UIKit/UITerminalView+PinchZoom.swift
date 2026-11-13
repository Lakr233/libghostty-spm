//
//  UITerminalView+PinchZoom.swift
//  libghostty-spm
//

#if canImport(UIKit)
    import UIKit

    /// Pinch gesture state; behavior lives in +PinchZoom. The font size the
    /// pinch steps is not kept here: the coordinator tracks it for every
    /// platform and every path that zooms (`fontSize`).
    struct FontZoomState {
        var pinch = TerminalPinchFontZoom()
    }

    #if targetEnvironment(macCatalyst)
        /// A pinch of two fingers on a Mac's touch display, and nothing
        /// else. A trackpad pinch reaches a pinch recognizer as a
        /// `.transform` event, not as touches; refusing it keeps every Mac
        /// without a touch display exactly where it was.
        final class TerminalDirectTouchPinchGestureRecognizer: UIPinchGestureRecognizer {
            override init(target: Any?, action: Selector?) {
                super.init(target: target, action: action)
                allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            }

            override func shouldReceive(_ event: UIEvent) -> Bool {
                event.type == .touches
            }
        }
    #endif

    extension UITerminalView {
        func setupPinchZoomGesture() {
            #if targetEnvironment(macCatalyst)
                let pinch = TerminalDirectTouchPinchGestureRecognizer(
                    target: self,
                    action: #selector(handlePinchGesture(_:)),
                )
            #else
                let pinch = UIPinchGestureRecognizer(
                    target: self,
                    action: #selector(handlePinchGesture(_:)),
                )
            #endif
            addGestureRecognizer(pinch)
        }

        @objc func handlePinchGesture(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:
                #if !targetEnvironment(macCatalyst)
                    softwareKeyboard.tapCandidateArmed = false
                #endif
                stopMomentumScrolling()
                dismissTouchSelection()
                fontZoom.pinch.begin(scale: gesture.scale)
                TerminalDebugLog.log(
                    .actions,
                    "pinch began scale=\(String(format: "%.3f", gesture.scale)) fontSize=\(fontSizeDescription)",
                )

            case .changed:
                let steps = fontZoom.pinch.takeSteps(at: gesture.scale)
                guard steps != 0 else { return }
                TerminalDebugLog.log(
                    .actions,
                    "pinch changed scale=\(String(format: "%.3f", gesture.scale)) steps=\(steps)",
                )

                if core.applyPinchFontZoom(steps: steps) {
                    refreshTextInputGeometry(reason: "pinch-zoom")
                    TerminalDebugLog.log(
                        .actions,
                        "pinch applied fontSize=\(fontSizeDescription)",
                    )
                }

            case .ended, .cancelled, .failed:
                fontZoom.pinch.end()
                TerminalDebugLog.log(
                    .actions,
                    "pinch ended state=\(gesture.state.rawValue) fontSize=\(fontSizeDescription)",
                )

            default:
                break
            }
        }

        private var fontSizeDescription: String {
            fontSize.map { "\($0)" } ?? "nil"
        }
    }
#endif
