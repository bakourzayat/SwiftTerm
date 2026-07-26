import Testing
@testable import SwiftTerm

/// kilter-patches: `TerminalOptions.altBufferScrollback` gives the alternate
/// screen a scrollback of its own (the iTerm2 deviation from xterm). The
/// tmux-shaped claim under test: when a full-screen multiplexer scrolls its
/// pane through a scroll region (status line pinned below), exactly the pane
/// lines that scroll off accumulate — while cursor-addressed repaints (vim,
/// TUIs) contribute nothing.
///
/// NOTE on counting: `Terminal.init` builds its buffers at the 80×25 ivar
/// defaults and only then resizes to the requested grid, and a scrollback-
/// bearing buffer deliberately keeps its lines when rows shrink. So a small
/// test grid starts with residual blank lines in the list — every assertion
/// here is therefore about DELTAS and ordering, never absolute line counts.
struct AltScreenScrollbackTests {
    private let esc = "\u{1B}"

    /// Raw text of one absolute line in the buffer's full list (scrollback
    /// included) — the harness's own line helpers are viewport-relative.
    private func absoluteLineText(_ buffer: Buffer, _ index: Int) -> String {
        buffer.translateBufferLineToString(lineIndex: index, trimRight: true)
    }

    private func allLines(_ buffer: Buffer) -> [String] {
        (0..<buffer.lines.count).map { absoluteLineText(buffer, $0) }
    }

    private func makeTerminal(cols: Int = 10, rows: Int = 5,
                              scrollback: Int = 50,
                              altScrollback: Bool) -> (Terminal, TerminalTestDelegate) {
        let delegate = TerminalTestDelegate()
        let options = TerminalOptions(cols: cols, rows: rows,
                                      scrollback: scrollback,
                                      altBufferScrollback: altScrollback)
        return (Terminal(delegate: delegate, options: options), delegate)
    }

    /// tmux-style setup: enter alt screen, paint a status line on the bottom
    /// row, confine the scroll region to the pane above it, park the cursor
    /// at the region's bottom.
    private func enterTmuxStyle(_ terminal: Terminal, rows: Int) {
        terminal.feed(text: "\(esc)[?1049h")
        terminal.feed(text: "\(esc)[\(rows);1HSTATUS")
        terminal.feed(text: "\(esc)[1;\(rows - 1)r")
        terminal.feed(text: "\(esc)[\(rows - 1);1H")
    }

    /// Numbered lines with LF at the region's bottom — the way tmux scrolls
    /// a pane (csr + index), which is what makes lines leave through the top.
    private func feedPaneLines(_ terminal: Terminal, _ range: ClosedRange<Int>) {
        for i in range {
            terminal.feed(text: "L\(i)\r\n")
        }
    }

    @Test func defaultAltScreenStillHasNoScrollback() {
        // At the construction geometry (80×25 — no shrink, so the list has
        // no slack capacity; a SHRUNK no-scrollback buffer has always been
        // able to splice into its leftover capacity, an upstream quirk this
        // patch does not touch). The default contract: region scrolling
        // never grows the alt screen's line list.
        let (terminal, _) = makeTerminal(cols: 80, rows: 25, altScrollback: false)
        enterTmuxStyle(terminal, rows: 25)
        let before = terminal.buffer.lines.count
        feedPaneLines(terminal, 1...60)
        #expect(terminal.buffer.hasScrollback == false)
        #expect(terminal.buffer.lines.count == before)
    }

    @Test func paneLinesAccumulateUnderAScrollRegion() {
        let rows = 5
        let (terminal, _) = makeTerminal(rows: rows, altScrollback: true)
        enterTmuxStyle(terminal, rows: rows)
        let before = terminal.buffer.lines.count
        feedPaneLines(terminal, 1...30)

        let buffer = terminal.buffer
        #expect(buffer.hasScrollback)
        // 30 lines through a 4-row pane: the pane shows the last few, the
        // rest must have grown the list — that growth IS the scrollback.
        #expect(buffer.lines.count > before + 20)

        // The status line never scrolls: it is still the bottom VISIBLE row.
        #expect(TerminalTestHarness.lineText(buffer: buffer, terminal: terminal,
                                             row: rows - 1) == "STATUS")

        // The history is the pane's own lines in order — L1 before L2 before
        // L15 — and the status line is never among the scrolled-off lines.
        let all = allLines(buffer)
        let i1 = all.firstIndex(of: "L1")
        let i2 = all.firstIndex(of: "L2")
        let i15 = all.firstIndex(of: "L15")
        #expect(i1 != nil && i2 != nil && i15 != nil)
        if let i1, let i2, let i15 {
            #expect(i1 < i2 && i2 < i15)
        }
        #expect(all.dropLast(1).filter { $0 == "STATUS" }.isEmpty)
    }

    @Test func scrollbackCeilingHoldsUnderRegionScroll() {
        // Tiny cap on purpose. Feed far past it twice: once the list is
        // full, more output must EVICT the oldest, never grow the list.
        let (terminal, _) = makeTerminal(scrollback: 5, altScrollback: true)
        enterTmuxStyle(terminal, rows: 5)
        feedPaneLines(terminal, 1...60)
        let full = terminal.buffer.lines.count
        feedPaneLines(terminal, 61...120)
        #expect(terminal.buffer.lines.count == full)
        // The newest pane line is on screen; the oldest is long evicted.
        let all = allLines(terminal.buffer)
        #expect(all.contains("L120"))
        #expect(!all.contains("L1"))
    }

    @Test func cursorAddressedRepaintsContributeNothing() {
        // The ghosting guard (kilter #8): a vim-style full repaint — cursor
        // home + rewrite every row, no LF at the region bottom — must not
        // grow the scrollback, no matter how often it repaints.
        let rows = 5
        let (terminal, _) = makeTerminal(rows: rows, altScrollback: true)
        terminal.feed(text: "\(esc)[?1049h")
        let before = terminal.buffer.lines.count
        for frame in 1...20 {
            for row in 1...rows {
                terminal.feed(text: "\(esc)[\(row);1H\(esc)[2Kframe\(frame)r\(row)")
            }
        }
        #expect(terminal.buffer.lines.count == before)
    }

    @Test func leavingTheAltScreenDropsItsScrollback() {
        // Documented edge, not an accident: `1049l` (tmux detach / exit)
        // clears the alt buffer, history included. A DROPPED link never
        // sends 1049l — which is why offline reading still works.
        let (terminal, _) = makeTerminal(altScrollback: true)
        enterTmuxStyle(terminal, rows: 5)
        feedPaneLines(terminal, 1...30)
        let grown = terminal.buffer.lines.count
        terminal.feed(text: "\(esc)[?1049l")
        terminal.feed(text: "\(esc)[?1049h")
        #expect(terminal.buffer.lines.count < grown)
        #expect(!allLines(terminal.buffer).contains("L1"))
    }

    @Test func selectionAnchorsSurviveMoreOutput() {
        // The point of the whole change (#31/#91/#106): text captured into
        // scrollback KEEPS its absolute position while new output arrives,
        // so a selection anchored there stays truthful. Absolute row of
        // "L5" must not move as 20 more lines stream in.
        let rows = 5
        let (terminal, _) = makeTerminal(rows: rows, altScrollback: true)
        enterTmuxStyle(terminal, rows: rows)
        feedPaneLines(terminal, 1...10)
        let buffer = terminal.buffer
        let rowOfL5 = allLines(buffer).firstIndex(of: "L5")
        #expect(rowOfL5 != nil)
        feedPaneLines(terminal, 11...30)
        #expect(absoluteLineText(buffer, rowOfL5 ?? 0) == "L5")
    }
}
