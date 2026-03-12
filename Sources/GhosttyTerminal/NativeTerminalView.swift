#if canImport(UIKit)
    import UIKit

    public typealias NativeTerminalView = UIKitTerminalView
#elseif canImport(AppKit)
    import AppKit

    public typealias NativeTerminalView = AppKitTerminalView
#endif
