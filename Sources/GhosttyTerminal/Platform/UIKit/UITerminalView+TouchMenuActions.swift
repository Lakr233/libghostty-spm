//
//  UITerminalView+TouchMenuActions.swift
//  libghostty-spm
//

#if canImport(UIKit)
    import UIKit

    extension UITerminalView {
        func defaultTouchMenuItems(at point: CGPoint, selecting: Bool) -> [UIMenuElement] {
            let paste = UIAction(
                title: String(localized: "Paste", bundle: .ghosttyTerminal),
                image: UIImage(systemName: "doc.on.clipboard"),
                identifier: UIAction.Identifier("terminal.paste"),
            ) { [weak self] _ in
                self?.dismissTouchSelection()
                self?.pasteFromPasteboard()
            }
            let select = UIAction(
                title: String(localized: "Select", bundle: .ghosttyTerminal),
                image: UIImage(systemName: "selection.pin.in.out"),
                identifier: UIAction.Identifier("terminal.select"),
            ) { [weak self] _ in
                self?.touchSelection.pendingAction = { [weak self] in
                    self?.beginTouchSelection(at: point, selectAll: false)
                }
            }
            let selectAll = UIAction(
                title: String(localized: "Select All", bundle: .ghosttyTerminal),
                image: UIImage(systemName: "character.textbox"),
                identifier: UIAction.Identifier("terminal.selectAll"),
            ) { [weak self] _ in
                self?.touchSelection.pendingAction = { [weak self] in
                    self?.beginTouchSelection(at: point, selectAll: true)
                }
            }
            let copy = UIAction(
                title: String(localized: "Copy", bundle: .ghosttyTerminal),
                image: UIImage(systemName: "doc.on.doc"),
                identifier: UIAction.Identifier("terminal.copy"),
            ) { [weak self] _ in
                _ = self?.copyTouchSelection()
            }
            let linkPoint = selecting ? touchSelection.menuPoint ?? point : point
            let openLink = UIAction(
                title: String(localized: "Open Link", bundle: .ghosttyTerminal),
                image: UIImage(systemName: "safari"),
                identifier: UIAction.Identifier("terminal.openLink"),
            ) { [weak self] _ in
                guard let self, let surface else { return }
                sendCommandClick(at: linkPoint, mods: .super_, on: surface)
                dismissTouchSelection()
            }
            let linkItems: [UIMenuElement] = touchLinkExists(at: linkPoint) ? [openLink] : []
            let pasteItems: [UIMenuElement] = TerminalPasteboardContent.hasContent() ? [paste] : []
            return linkItems + (selecting ? [copy] + pasteItems + [selectAll] : pasteItems + [select, selectAll])
        }
    }
#endif
