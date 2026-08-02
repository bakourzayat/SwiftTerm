//
// KilterTerminalAdditions.swift — kilter's attach-time scrollback backfill.
//
// With `altBufferScrollback` on, the alt screen accumulates the lines tmux
// scrolls off its pane — but only from the moment of attach. tmux repaints
// the screen cursor-addressed on attach, so history from BEFORE the attach
// exists only server-side. kilter fetches it out-of-band
// (`tmux capture-pane -p -e -J -S …`) and prepends it here, so scrolling
// up works from the first minute of a session, not just after fresh output.
//
import Foundation

/// Swallows every callback: the scratch terminal used to parse captured
/// history has no screen, sends nothing, and nobody listens.
private final class KilterNoopTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
    func showCursor(source: Terminal) {}
    func hideCursor(source: Terminal) {}
    func setTerminalTitle(source: Terminal, title: String) {}
    func setTerminalIconTitle(source: Terminal, title: String) {}
    func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { nil }
    func sizeChanged(source: Terminal) {}
    func scrolled(source: Terminal, yDisp: Int) {}
    func linefeed(source: Terminal) {}
    func bufferActivated(source: Terminal) {}
    func bell(source: Terminal) {}
    func selectionChanged(source: Terminal) {}
    func isProcessTrusted(source: Terminal) -> Bool { true }
    func mouseModeChanged(source: Terminal) {}
    func cellSizeInPixels(source: Terminal) -> (width: Int, height: Int)? { nil }
}

public extension Terminal {
    /// Parse a raw tmux `capture-pane` dump (SGR escapes welcome — pass
    /// `-e`) into standalone `BufferLine`s wrapped at `cols`. The capture
    /// should be taken with `-J` so tmux hands back logical lines; the
    /// scratch terminal re-wraps them to the live grid's width. Leading and
    /// trailing blank lines are trimmed; interior blanks are content.
    static func kilterParseHistory(raw: [UInt8], cols: Int) -> [BufferLine] {
        guard !raw.isEmpty, cols > 0 else { return [] }
        let delegate = KilterNoopTerminalDelegate()
        // convertEol: capture output separates lines with bare LF.
        // Generous scrollback so a deep capture survives the parse; the
        // caller trims to what actually fits before prepending.
        let scratch = Terminal(delegate: delegate,
                               options: TerminalOptions(cols: cols,
                                                        convertEol: true,
                                                        scrollback: 10_000))
        scratch.feed(buffer: raw[...])
        let buffer = scratch.buffer
        let all = buffer.lines
        // Find the content window: skip construction-artifact and padding
        // blanks at both ends (the scratch buffer is born 80×25 and resized,
        // and a short capture leaves unused viewport rows below).
        func isBlank(_ i: Int) -> Bool {
            buffer.translateBufferLineToString(lineIndex: i, trimRight: true).isEmpty
        }
        var first = 0
        var last = all.count - 1
        while first <= last, isBlank(first) { first += 1 }
        while last >= first, isBlank(last) { last -= 1 }
        guard first <= last else { return [] }
        return (first...last).map { all[$0] }
    }

    /// Prepend already-parsed lines ABOVE the current buffer's content —
    /// the attach-time backfill. Only buffers with scrollback accept it.
    /// When capacity is short the OLDEST prepended lines are dropped (the
    /// newest history sits closest to the live screen, exactly like a
    /// scrollback that had simply been running longer). Returns the number
    /// of lines actually inserted; the caller owns display refresh.
    @discardableResult
    func kilterPrependScrollback(_ newLines: [BufferLine]) -> Int {
        let buffer = self.buffer
        guard buffer.hasScrollback, !newLines.isEmpty else { return 0 }
        let capacity = buffer.lines.maxLength - buffer.lines.count
        guard capacity > 0 else { return 0 }
        let taken = Array(newLines.suffix(capacity))
        buffer.lines.splice(start: 0, deleteCount: 0, items: taken) { _ in }
        // The visible window (and the cursor's home) live at yBase; shifting
        // both by the insertion keeps the live screen exactly where it was.
        buffer.yBase += taken.count
        buffer.yDisp += taken.count
        return taken.count
    }

    /// Drop everything ABOVE the live screen on the current buffer — the
    /// reflow-garbage flush (kelter 2026-08-02).
    ///
    /// Why it exists: with `altBufferScrollback` on, a RESIZE reflows the
    /// alt screen and the rows that no longer fit are shed into the local
    /// scrollback — renderings of a width that no longer exists. Measured
    /// on a live tmux session: every phone rotation grew the alt buffer by
    /// a screenful (204 → 220 → 238 lines), stale frames stacking above
    /// the live one. Scrolled up, they render as overlapping copies of the
    /// UI at mixed widths — the owner's "ghosting".
    ///
    /// The caller drops the garbage and re-backfills the truth from tmux
    /// (`capture-pane` re-wrapped at the NEW width). Returns lines removed.
    @discardableResult
    func kilterDropScrollback() -> Int {
        let buffer = self.buffer
        let n = buffer.yBase
        guard n > 0 else { return 0 }
        buffer.lines.splice(start: 0, deleteCount: n, items: []) { _ in }
        buffer.yBase = 0
        buffer.yDisp = 0
        return n
    }
}
