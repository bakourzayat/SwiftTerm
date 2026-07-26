import Testing
@testable import SwiftTerm

/// kilter-patches: attach-time scrollback backfill — parsing a tmux
/// `capture-pane` dump into BufferLines and prepending them above the live
/// alt-screen content without disturbing the visible screen.
struct KilterBackfillTests {
    private let esc = "\u{1B}"

    private func line(_ buffer: Buffer, _ i: Int) -> String {
        buffer.translateBufferLineToString(lineIndex: i, trimRight: true)
    }

    // MARK: parse

    @Test func parseSplitsTrimsAndKeepsInteriorBlanks() {
        let raw = Array("\n\nalpha\nbeta\n\ngamma\n\n\n".utf8)
        let lines = Terminal.kilterParseHistory(raw: raw, cols: 20)
        let texts = lines.enumerated().map { i, _ -> String in
            let scratch = BufferLineRenderProbe(lines: lines)
            return scratch.text(at: i)
        }
        #expect(texts == ["alpha", "beta", "", "gamma"])
    }

    @Test func parseRewrapsToRequestedWidth() {
        // 25 chars at cols 10 → 3 rows, the continuation rows wrapped.
        let raw = Array("abcdefghijklmnopqrstuvwxy\n".utf8)
        let lines = Terminal.kilterParseHistory(raw: raw, cols: 10)
        #expect(lines.count == 3)
        #expect(lines[1].isWrapped)
        #expect(lines[2].isWrapped)
        #expect(!lines[0].isWrapped)
    }

    @Test func parseKeepsSGRColors() {
        let raw = Array("\(esc)[31mred\(esc)[0m plain\n".utf8)
        let lines = Terminal.kilterParseHistory(raw: raw, cols: 20)
        #expect(lines.count == 1)
        // The first three cells carry a non-default fg attribute.
        let attr = lines[0][0].attribute
        #expect(attr.fg != CharData.defaultAttr.fg)
    }

    @Test func parseEmptyAndBlankGiveNothing() {
        #expect(Terminal.kilterParseHistory(raw: [], cols: 20).isEmpty)
        #expect(Terminal.kilterParseHistory(raw: Array("\n\n\n".utf8), cols: 20).isEmpty)
    }

    // MARK: prepend

    private func makeAltTerminal() -> Terminal {
        let delegate = TerminalTestDelegate()
        let options = TerminalOptions(cols: 20, rows: 25,
                                      scrollback: 100,
                                      altBufferScrollback: true)
        let terminal = Terminal(delegate: delegate, options: options)
        terminal.feed(text: "\u{1B}[?1049h")
        terminal.feed(text: "\u{1B}[1;1HLIVE-TOP")
        terminal.feed(text: "\u{1B}[25;1HLIVE-BOTTOM")
        return terminal
    }

    @Test func prependKeepsTheVisibleScreenIdentical() {
        let terminal = makeAltTerminal()
        let buffer = terminal.buffer
        let beforeTop = TerminalTestHarness.lineText(buffer: buffer, terminal: terminal, row: 0)
        let beforeBottom = TerminalTestHarness.lineText(buffer: buffer, terminal: terminal, row: 24)

        let history = Terminal.kilterParseHistory(raw: Array("old-1\nold-2\nold-3\n".utf8), cols: 20)
        let n = terminal.kilterPrependScrollback(history)
        #expect(n == 3)

        // The viewport shows exactly what it showed.
        #expect(TerminalTestHarness.lineText(buffer: buffer, terminal: terminal, row: 0) == beforeTop)
        #expect(TerminalTestHarness.lineText(buffer: buffer, terminal: terminal, row: 24) == beforeBottom)
        // And the history sits above it, oldest first.
        #expect(line(buffer, 0) == "old-1")
        #expect(line(buffer, 2) == "old-3")
    }

    @Test func prependCapsAtCapacityKeepingNewestHistory() {
        let delegate = TerminalTestDelegate()
        // Tiny cap: 25 rows + 5 scrollback.
        let options = TerminalOptions(cols: 20, rows: 25, scrollback: 5,
                                      altBufferScrollback: true)
        let terminal = Terminal(delegate: delegate, options: options)
        terminal.feed(text: "\u{1B}[?1049h")
        let history = Terminal.kilterParseHistory(
            raw: Array((1...40).map { "old-\($0)" }.joined(separator: "\n").utf8),
            cols: 20)
        let n = terminal.kilterPrependScrollback(history)
        #expect(n <= 5)
        #expect(n > 0)
        // The NEWEST history lines survive — the ones nearest the screen.
        #expect(line(terminal.buffer, n - 1) == "old-40")
        _ = delegate
    }

    @Test func prependRefusesABufferWithoutScrollback() {
        let delegate = TerminalTestDelegate()
        let options = TerminalOptions(cols: 20, rows: 25, scrollback: 50,
                                      altBufferScrollback: false)
        let terminal = Terminal(delegate: delegate, options: options)
        terminal.feed(text: "\u{1B}[?1049h")
        let history = Terminal.kilterParseHistory(raw: Array("old\n".utf8), cols: 20)
        #expect(terminal.kilterPrependScrollback(history) == 0)
        _ = delegate
    }

    @Test func liveScrollingContinuesCorrectlyAfterAPrepend() {
        let terminal = makeAltTerminal()
        let history = Terminal.kilterParseHistory(raw: Array("old-1\nold-2\n".utf8), cols: 20)
        _ = terminal.kilterPrependScrollback(history)
        // New pane output must keep appending under the same geometry.
        // (2K clears LIVE-BOTTOM first — without it the first write lands
        // on top of the old row text and reads "new-1BOTTOM".)
        terminal.feed(text: "\u{1B}[25;1H\u{1B}[2K")
        for i in 1...5 { terminal.feed(text: "new-\(i)\r\n") }
        let all = (0..<terminal.buffer.lines.count).map { line(terminal.buffer, $0) }
        let iOld = all.firstIndex(of: "old-2")
        let iNew = all.firstIndex(of: "new-1")
        #expect(iOld != nil && iNew != nil)
        if let iOld, let iNew { #expect(iOld < iNew) }
    }
}

/// Reads text back out of standalone BufferLines (they carry their own
/// cells; a throwaway buffer is only needed for the translate helper).
private struct BufferLineRenderProbe {
    let lines: [BufferLine]
    func text(at index: Int) -> String {
        var out = ""
        let line = lines[index]
        for col in 0..<line.count {
            let ch = line[col].getCharacter()
            out.append(ch == "\u{0}" ? " " : ch)
        }
        while out.hasSuffix(" ") { out.removeLast() }
        return out
    }
}
