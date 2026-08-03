//
// KilterBufferLine.swift — kilter's read-only window into wrap state.
//
// The reader page re-joins hard-wrapped rows into real paragraphs: the
// terminal is the only party that KNOWS which line breaks are soft (a
// column boundary) and which are content. `isWrapped` is internal upstream;
// this exposes it read-only, nothing else.
//
import Foundation

public extension BufferLine {
    /// True when this row CONTINUES the previous one — the terminal wrapped
    /// a logical line at the column boundary rather than receiving a real
    /// newline. Read-only: reflow stays the terminal's business.
    var kilterIsWrapped: Bool { isWrapped }
}
