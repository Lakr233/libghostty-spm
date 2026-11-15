//
//  TerminalSearchEvent.swift
//  libghostty-spm
//

/// One report from Ghostty's scrollback search, as
/// ``TerminalViewState/onSearch`` passes it on.
public enum TerminalSearchEvent: Equatable, Sendable {
    /// A binding asked for a search to be shown (`start_search`,
    /// `search_selection`). The needle is the text it starts from, such as
    /// the selection; nil when there is none.
    case started(needle: String?)
    /// The `end_search` binding ran. Ghostty reports it whether or not a
    /// search was running.
    case ended
    /// How many matches the running search has found; nil while unknown.
    case total(Int?)
    /// The index of the selected match; nil when none is selected.
    case selected(Int?)
}
