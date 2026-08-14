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

/// §1.8 — what the user selected, anchored to CONTENT (owner 2026-08-13
/// night: *"the same behavior as any text on my iPhone — I can scroll
/// anywhere and come back, and it's still selected"*). On the alternate
/// screen the remote repaints rows in place, so a cell-anchored selection
/// either dies (the old clear-on-scroll) or lies (the July wrong-text
/// bug). This remembers the TEXT with its line context; after repaints
/// the view re-finds it, hides the highlight while its text is off
/// screen (dormant, never dead), and restores it when the text returns.
struct KilterSelectionAnchor {
    var text: String
    /// The first LINE of the selected text itself — the search needle.
    /// NOT the full terminal row: on a multi-pane TUI (herdr) the row
    /// also contains the rail beside the transcript, which does NOT move
    /// when the pane scrolls — full-row matching only ever succeeded at
    /// the original position (owner walk 2026-08-14: "you can see the
    /// sentence, but you cannot see the marking until you go back").
    var firstSelLine: String
    var startCol: Int
    var endCol: Int
    var rowSpan: Int
    var lastStartRow: Int
}

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

    /// §1.8 — capture the anchor at every USER selection change (wired in
    /// `selectionChanged`, guarded against the re-anchorer's own writes).
    /// A real deactivation — the user dismissing — drops the anchor; the
    /// dormancy path deactivates with the guard flag up, so its anchor
    /// survives to resurrect the selection when the text scrolls back.
    internal func kilterCaptureSelectionAnchor() {
        // DEACTIVATION NEVER DROPS THE ANCHOR (owner 2026-08-13, "three
        // steps and it's gone"). Selection-changed notifications arrive
        // ASYNC, after the re-anchorer's guard flag has already reset —
        // so the dormancy's own selectNone came back through this hook
        // reading as a user dismissal and erased the anchor it was meant
        // to protect. SwiftTerm's internal invalidations did the same.
        // Only `kilterClearSelectionAnchor()` — the user's explicit
        // dismissal, called by the app — drops it now.
        guard selection.active else { return }
        let t = getTerminal()
        guard t.isCurrentBufferAlternate else {
            kilterAnchor = nil   // a fresh selection elsewhere replaces it
            return
        }
        let s = selection.start, e = selection.end
        let text = t.getText(start: s, end: e)
        guard !text.isEmpty else { return }
        let firstSel = text.split(separator: "\n", omittingEmptySubsequences: false)
            .first.map(String.init) ?? text
        guard !firstSel.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        kilterAnchor = KilterSelectionAnchor(
            text: text,
            firstSelLine: firstSel,
            startCol: s.col, endCol: e.col,
            rowSpan: e.row - s.row, lastStartRow: s.row)
    }

    /// §1.8 — the ONE way the anchor dies: the user dismissed the
    /// selection on purpose. kelter calls this at its deliberate
    /// clear sites (the grid tap, entering reading mode).
    func kilterClearSelectionAnchor() {
        kilterAnchor = nil
    }

    /// §1.8 — after a repaint, put the highlight back on its TEXT. Fast
    /// path: unchanged where it stands. Otherwise search the display
    /// buffer for the anchor's start line (nearest to where it last
    /// stood), verify the whole span, and move the selection there. Not
    /// found = the text is off screen: the highlight goes DORMANT (the
    /// anchor survives) and returns with the text. Called by kelter's
    /// renderer on the throttled redraw hook.
    func kilterRevalidateSelection() {
        let t = getTerminal()
        guard t.isCurrentBufferAlternate, let anchor = kilterAnchor else { return }
        kilterReanchoring = true
        defer { kilterReanchoring = false }
        if selection.active,
           t.getText(start: selection.start, end: selection.end) == anchor.text {
            kilterAnchor?.lastStartRow = selection.start.row
            return
        }
        // Search by the SELECTED TEXT at its own column — vertical pane
        // scrolls keep columns, and whatever sits beside the pane (a
        // rail, a border) cannot poison the match the way full-row
        // equality did. The full-span getText verification below still
        // gates every candidate.
        let buffer = t.displayBuffer
        let rows = buffer.lines.count
        var best: Int?
        for row in 0..<rows {
            guard row + anchor.rowSpan < rows else { break }
            let tail = buffer.lines[row].translateToString(
                trimRight: true, startCol: anchor.startCol)
            guard tail.hasPrefix(anchor.firstSelLine) else { continue }
            if let b = best,
               abs(b - anchor.lastStartRow) <= abs(row - anchor.lastStartRow) { continue }
            best = row
        }
        if let row = best {
            let s = Position(col: anchor.startCol, row: row)
            let e = Position(col: anchor.endCol, row: row + anchor.rowSpan)
            guard t.getText(start: s, end: e) == anchor.text else {
                if selection.active { selection.selectNone(); requestDisplay() }
                return
            }
            selection.setSelection(start: s, end: e)
            kilterAnchor?.lastStartRow = row
            requestDisplay()
        } else if selection.active {
            selection.selectNone()
            requestDisplay()
        }
    }

    /// Full trimmed text of one display-buffer row — the anchor's context.
    internal func kilterLineText(_ row: Int) -> String {
        let buffer = getTerminal().displayBuffer
        guard row >= 0, row < buffer.lines.count else { return "" }
        return buffer.lines[row].translateToString(trimRight: true)
    }

    /// §1.7 — handle-only extension (kelter round 12, owner 2026-08-13:
    /// *"if you select, you cannot scroll"*). True when a VIEW-space touch
    /// point lands near either selection edge — the zone a finger means as
    /// "grab the handle". Everywhere else on the glass a drag means
    /// SCROLL, selection intact; the selection pan's begin-gate and the
    /// app's one-finger scroll both consult this so they can never claim
    /// the same touch. The window mirrors the extend-pan's own `near()`
    /// tolerance (±3 cols, ±2 rows), padded to a finger's width.
    func kilterTouchIsNearSelectionEdge(_ point: CGPoint) -> Bool {
        guard selection.active else { return false }
        // A touch ON a grabber IS a handle grab, wherever the dot floats
        // (owner 2026-08-14: grabbing a handle also scrolled — the dot
        // sits just OUTSIDE the text-proximity window, so the scroll
        // gesture began simultaneously with the handle drag). The handle
        // views answer first, padded to a fingertip.
        for sub in subviews where sub is KilterSelectionHandleView {
            if sub.frame.insetBy(dx: -16, dy: -16).contains(point) { return true }
        }
        // View → content space (the selection rows are content-absolute).
        let content = CGPoint(x: point.x, y: point.y + contentOffset.y)
        let cw = cellDimension.width, ch = cellDimension.height
        func nearEdge(_ p: Position) -> Bool {
            let rect = CGRect(x: CGFloat(p.col) * cw, y: CGFloat(p.row) * ch,
                              width: cw, height: ch)
                .insetBy(dx: -(cw * 3), dy: -(ch * 2))
            return rect.contains(content)
        }
        return nearEdge(selection.start) || nearEdge(selection.end)
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