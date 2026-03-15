import Foundation
import GhosttyKit

public struct TerminalHostManagedResize: Sendable, Equatable {
    public var columns: UInt16
    public var rows: UInt16
    public var widthPixels: UInt32
    public var heightPixels: UInt32
    public var cellWidthPixels: UInt32
    public var cellHeightPixels: UInt32

    public init(
        columns: UInt16,
        rows: UInt16,
        widthPixels: UInt32 = 0,
        heightPixels: UInt32 = 0,
        cellWidthPixels: UInt32 = 0,
        cellHeightPixels: UInt32 = 0
    ) {
        self.columns = columns
        self.rows = rows
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
        self.cellWidthPixels = cellWidthPixels
        self.cellHeightPixels = cellHeightPixels
    }
}

public final class TerminalHostManagedSession: @unchecked Sendable {
    private let lock = NSLock()
    private var surface: ghostty_surface_t?
    private var lastResize: TerminalHostManagedResize?
    private let writeHandler: @Sendable (Data) -> Void
    private let resizeHandler: @Sendable (TerminalHostManagedResize) -> Void

    public init(
        write: @escaping @Sendable (Data) -> Void,
        resize: @escaping @Sendable (TerminalHostManagedResize) -> Void
    ) {
        writeHandler = write
        resizeHandler = resize
    }

    // MARK: - Surface Lifecycle

    func setSurface(_ surface: ghostty_surface_t?) {
        lock.lock()
        defer { lock.unlock() }
        self.surface = surface
    }

    func updateViewport(_ size: TerminalSurfaceSize) {
        dispatchResize(TerminalHostManagedResize(
            columns: size.columns,
            rows: size.rows,
            widthPixels: size.widthPixels,
            heightPixels: size.heightPixels,
            cellWidthPixels: size.cellWidthPixels,
            cellHeightPixels: size.cellHeightPixels
        ))
    }

    // MARK: - Receiving Data

    /// Feed data into the terminal from the host backend.
    public func receive(_ data: Data) {
        lock.lock()
        guard let surface else {
            lock.unlock()
            return
        }
        lock.unlock()

        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            ghostty_surface_write_buffer(surface, ptr, UInt(buffer.count))
        }
    }

    /// Feed a UTF-8 string into the terminal from the host backend.
    public func receive(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        receive(data)
    }

    // MARK: - Process Exit

    /// Signal that the host-managed process has exited.
    public func finish(exitCode: UInt32, runtimeMilliseconds: UInt64) {
        lock.lock()
        guard let surface else {
            lock.unlock()
            return
        }
        lock.unlock()

        ghostty_surface_process_exit(surface, exitCode, runtimeMilliseconds)
    }

    // MARK: - C Callbacks

    static let receiveBufferCallback: ghostty_surface_receive_buffer_cb = { userdata, ptr, len in
        guard let userdata, let ptr else { return }
        let session = Unmanaged<TerminalHostManagedSession>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        let data = Data(bytes: ptr, count: len)
        session.writeHandler(data)
    }

    static let receiveResizeCallback: ghostty_surface_receive_resize_cb = { userdata, cols, rows, widthPx, heightPx in
        guard let userdata else { return }
        let session = Unmanaged<TerminalHostManagedSession>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        session.dispatchResize(TerminalHostManagedResize(
            columns: cols,
            rows: rows,
            widthPixels: widthPx,
            heightPixels: heightPx
        ))
    }

    private func dispatchResize(_ resize: TerminalHostManagedResize) {
        lock.lock()
        let mergedResize = mergedResize(resize)
        guard mergedResize != lastResize else {
            lock.unlock()
            return
        }
        lastResize = mergedResize
        lock.unlock()

        resizeHandler(mergedResize)
    }

    private func mergedResize(_ resize: TerminalHostManagedResize) -> TerminalHostManagedResize {
        guard let lastResize else { return resize }

        return TerminalHostManagedResize(
            columns: resize.columns,
            rows: resize.rows,
            widthPixels: resize.widthPixels == 0 ? lastResize.widthPixels : resize.widthPixels,
            heightPixels: resize.heightPixels == 0 ? lastResize.heightPixels : resize.heightPixels,
            cellWidthPixels: resize.cellWidthPixels == 0 ? lastResize.cellWidthPixels : resize.cellWidthPixels,
            cellHeightPixels: resize.cellHeightPixels == 0 ? lastResize.cellHeightPixels : resize.cellHeightPixels
        )
    }
}
