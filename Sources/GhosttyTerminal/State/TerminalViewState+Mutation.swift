//
//  TerminalViewState+Mutation.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

import SwiftUI

public extension TerminalViewState {
    func adopt(colorScheme: ColorScheme) {
        let nextColorScheme = TerminalColorScheme(colorScheme)
        guard nextColorScheme != controller.effectiveColorScheme else { return }
        controller.setColorScheme(nextColorScheme)
    }

    @discardableResult
    func setTheme(_ theme: TerminalTheme) -> Bool {
        controller.setTheme(theme)
    }

    @discardableResult
    func setTerminalConfiguration(
        _ terminalConfiguration: TerminalConfiguration
    ) -> Bool {
        controller.setTerminalConfiguration(terminalConfiguration)
    }
}
