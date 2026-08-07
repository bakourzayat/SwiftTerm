//
// KilterAdditions.swift — kilter's public bridge to selection + metrics.
//
// Upstream keeps `selection` and `cellDimension` internal; kilter's Apple
// Pencil input needs to DRIVE selection programmatically (pencil-down =
// begin, drag = extend) and to place hover indicators on exact cells.
// Everything here forwards to existing public SelectionService methods.
//
#if os(iOS) || os(visionOS)
import Foundation
import CoreGraphics

public extension TerminalView {
    /// Grid metrics for one character cell (hover beams, overlays).
    var kilterCellSize: CGSize { cellDimension }

    /// The grid position under a view-space point, clamped to the buffer.
    func kilterGridPosition(at point: CGPoint) -> (col: Int, row: Int) {
        let hit = calculateTapHit(point: point)
        return (hit.grid.col, hit.grid.row)
    }

    /// The content-absolute buffer position under a view-space point.
    /// `calculateTapHit` already divides the CONTENT-space y (a scrolled
    /// UIScrollView's own coordinates include the offset) by the cell
    /// height, so its row is buffer-absolute — it must feed the
    /// `bufferPosition` selection APIs, never the screen-relative `row:col:`
    /// conveniences, which ADD `yDisp` a second time. Invisible while the
    /// alt screen had no scrollback (yDisp was 0 there); wrong the moment
    /// it does.
    private func kilterContentPosition(at point: CGPoint) -> Position {
        let hit = calculateTapHit(point: point).grid
        return Position(col: hit.col, row: hit.row)
    }

    /// Begin a character selection at the given view-space point.
    func kilterBeginSelection(at point: CGPoint) {
        selection.setSoftStart(bufferPosition: kilterContentPosition(at: point))
        selection.startSelection()
        // Arm the same drag-to-extend pan a double-tap arms. A selection
        // that cannot be slid afterwards is not the selection the product
        // ships — and the rigs that verify handle drags (kelter #33) must
        // exercise the exact same recognizer the finger meets.
        enableSelectionPanGesture()
        setNeedsDisplay(bounds)
    }

    /// Extend the active selection to the given view-space point. Anchored
    /// on `selection.start` directly — the pivot-based extends depend on a
    /// pivot that is nil'd on every deactivation and never re-seeded.
    func kilterExtendSelection(to point: CGPoint) {
        guard selection.active else {
            kilterBeginSelection(at: point)
            return
        }
        selection.setSelection(start: selection.start,
                               end: kilterContentPosition(at: point))
        setNeedsDisplay(bounds)
    }

    /// Turn SwiftTerm's OWN selection engine on/off (taps, long-press, and
    /// the selection pan). kilter disables it in Read mode so a single
    /// custom drag gesture is the sole selector — one engine, one highlight.
    func kilterSetNativeSelectionEnabled(_ on: Bool) {
        for g in kilterNativeSelectionGestures { g.isEnabled = on }
        if on { enableSelectionPanGesture() } else { disableSelectionPanGesture() }
    }

    /// Content-space rect of the active selection's end cell — the anchor
    /// kilter re-hangs the edit menu on after a local scroll (selection
    /// rows are content-absolute, so this tracks the text, not the glass).
    var kilterSelectionEndRect: CGRect? {
        guard selection.active else { return nil }
        return CGRect(x: CGFloat(selection.end.col) * cellDimension.width,
                      y: CGFloat(selection.end.row) * cellDimension.height,
                      width: cellDimension.width,
                      height: cellDimension.height)
    }

    /// How deep the CURRENTLY DISPLAYED buffer actually is, and what it was
    /// allowed to be. kilter's rig reads this to answer "why does scrollback
    /// stop?" with a number instead of a theory — `displayBuffer` is internal
    /// upstream, and the normal and alternate buffers are built at different
    /// moments, so which one you are looking at matters.
    var kilterBufferDepth: (lines: Int, capacity: Int, top: Int, isAlt: Bool) {
        let t = getTerminal()
        let b = t.displayBuffer
        return (b.lines.count,
                t.options.scrollback,
                b.linesTop,
                t.isCurrentBufferAlternate)
    }

    /// Attach-time scrollback backfill: parse a raw tmux `capture-pane`
    /// dump (take it with `-e -J`) and prepend it above the live screen,
    /// keeping the glass stable — at the live edge the view stays pinned;
    /// scrolled up, the offset shifts by the insertion so the text under
    /// the reader's eyes does not move. Returns lines inserted.
    @discardableResult
    func kilterBackfillScrollback(rawHistory: [UInt8]) -> Int {
        let lines = Terminal.kilterParseHistory(raw: rawHistory, cols: terminal.cols)
        guard !lines.isEmpty else { return 0 }
        // A selection's absolute rows would all shift; at attach time there
        // is nothing worth keeping — drop it rather than let it lie.
        if selection.active { selection.selectNone() }
        let bottomBefore = max(0, contentSize.height - bounds.height)
        let wasAtEdge = contentOffset.y >= bottomBefore - cellDimension.height / 2
        let n = terminal.kilterPrependScrollback(lines)
        guard n > 0 else { return 0 }
        updateScroller()
        if !wasAtEdge {
            let bottom = max(0, contentSize.height - bounds.height)
            let held = contentOffset.y + CGFloat(n) * cellDimension.height
            contentOffset = CGPoint(x: 0, y: min(held, bottom))
        }
        setNeedsDisplay(bounds)
        return n
    }

    /// View-level reflow flush — see `Terminal.kilterDropScrollback`. Drops
    /// the stale lines, kills any selection anchored to rows that no longer
    /// exist, and pins the view back to the live edge. Returns lines removed.
    @discardableResult
    func kilterDropScrollback() -> Int {
        if selection.active { selection.selectNone() }
        let n = terminal.kilterDropScrollback()
        guard n > 0 else { return 0 }
        updateScroller()
        contentOffset = CGPoint(x: 0, y: max(0, contentSize.height - bounds.height))
        setNeedsDisplay(bounds)
        return n
    }
}
#endif