//
//  TerminalView+Process.swift
//  libghostty-spm
//
//  Public read access to the pty's foreground process, available on both
//  AppKit (`AppTerminalView`) and UIKit (`UITerminalView`) hosts via the
//  `TerminalView` typealias. Both concrete views expose the same internal
//  `surface` accessor, so a single extension covers every platform.
//

import Foundation

public extension TerminalView {
    /// PID of the pty's foreground process group (`tcgetpgrp(pty)`). When the
    /// user runs a program in the pty this is that program's pid, so hosts can
    /// correlate the surface with an external process list. Nil until the
    /// surface has a process.
    ///
    /// On the pinned Ghostty (1.3.1) this is nil for every backend:
    /// `ghostty_surface_foreground_pid` returns 0 there. It populates once
    /// the pinned release carries the process-info API.
    var foregroundPid: pid_t? {
        surface?.foregroundPid
    }

    /// Name of the pty's controlling tty (e.g. `/dev/ttys004`), or nil until
    /// the surface has a process.
    ///
    /// On the pinned Ghostty (1.3.1) this is nil for every backend:
    /// `ghostty_surface_tty_name` returns an empty name there. It populates
    /// once the pinned release carries the process-info API.
    var ttyName: String? {
        surface?.ttyName
    }
}
