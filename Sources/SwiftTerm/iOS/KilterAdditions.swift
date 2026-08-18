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
#if canImport(MetalKit)
import MetalKit
#endif

// §1.8's TYPES AND ITS LAW now live in
// `Sources/SwiftTerm/Kilter/KilterSelectionAnchorPolicy.swift` —
// platform-free and pure, so kelter's `swift test` suite can assert the
// owner's words against them (that file explains why). What stays here
// is the UIKit half: reading the buffer, moving the selection, asking
// the renderer to paint. Every JUDGEMENT below is the policy's.

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
        kilterCaptureSelectionAnchor()   // §1.8: pencil-down is a user gesture
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
        kilterCaptureSelectionAnchor()   // §1.8: pencil drag is a user gesture
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

    /// Content-space bounding rect of the whole active selection — what
    /// kelter's own verb strip positions itself against. Single row hugs
    /// the selected cells; a multi-row span is full width, the way iOS
    /// frames a paragraph selection.
    var kilterSelectionContentRect: CGRect? {
        guard selection.active else { return nil }
        let cw = cellDimension.width, ch = cellDimension.height
        let s = selection.start, e = selection.end
        if s.row == e.row {
            let width = CGFloat(max(1, e.col - s.col + 1)) * cw
            return CGRect(x: CGFloat(s.col) * cw, y: CGFloat(s.row) * ch,
                          width: width, height: ch)
        }
        return CGRect(x: 0, y: CGFloat(s.row) * ch,
                      width: CGFloat(terminal.cols) * cw,
                      height: CGFloat(e.row - s.row + 1) * ch)
    }

    /// True when a view-space point lands ON the highlighted span itself —
    /// the owner's tap grammar (2026-08-14): a tap on the selection summons
    /// its verbs; a tap anywhere else is a dismissal. Uses the same
    /// `calculateTapHit` mapping every gesture uses, so the two can never
    /// disagree about what "on it" means.
    func kilterPointIsInSelection(_ point: CGPoint) -> Bool {
        guard selection.active else { return false }
        let hit = calculateTapHit(point: point).grid
        let s = selection.start, e = selection.end
        guard hit.row >= s.row, hit.row <= e.row else { return false }
        if s.row == e.row { return hit.col >= s.col && hit.col <= e.col }
        if hit.row == s.row { return hit.col >= s.col }
        if hit.row == e.row { return hit.col <= e.col }
        return true
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
        // to protect. The law is `KilterAnchorPolicy.verdict(for:)` now:
        // `.selectionDeactivated` is `.keep`, and there is exactly one
        // way to reach `.drop`.
        guard selection.active else {
            _ = KilterAnchorPolicy.verdict(for: .selectionDeactivated)  // .keep
            return
        }
        let t = getTerminal()
        let onAlt = t.isCurrentBufferAlternate
        switch KilterAnchorPolicy.verdict(
            for: .userGestureChangedSelection(onAlternateBuffer: onAlt)) {
        case .keep:
            return
        case .drop:
            // Normal buffer: rows are content-absolute and survive a
            // scroll by construction, so a fresh selection here replaces
            // the anchor with nothing rather than leaving a stale one.
            kilterAnchor = nil
            return
        case .recapture:
            break
        }
        let s = selection.start, e = selection.end
        let text = kilterNormalizedSpan(t.getText(start: s, end: e))
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
        // The app's two deliberate sites (the grid tap on a still glass,
        // entering reading mode) are the only callers, and both map to a
        // policy verdict of `.drop`. Asserted here so a third caller with
        // a different meaning cannot quietly join them.
        guard KilterAnchorPolicy.verdict(for: .userDismissedDeliberately) == .drop
        else { return }
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
        // §1.9 round 2: while an edge drag scrolls the remote, the pivot
        // needle (KilterSelectionHandles) owns the selection — re-anchoring
        // against mid-flight paint here would fight the finger.
        guard !kilterEdgeDragActive else { return }
        let t = getTerminal()
        guard t.isCurrentBufferAlternate, let anchor = kilterAnchor else { return }
        kilterReanchoring = true
        defer { kilterReanchoring = false }
        let buffer = t.displayBuffer
        let landing = KilterAnchorPolicy.locate(
            anchor: anchor,
            activeSpan: selection.active
                ? kilterNormalizedSpan(t.getText(start: selection.start,
                                                 end: selection.end))
                : nil,
            rowCount: buffer.lines.count,
            rowTail: { row in
                buffer.lines[row].translateToString(
                    trimRight: true, startCol: anchor.startCol)
            },
            spanText: { row in
                kilterNormalizedSpan(t.getText(
                    start: Position(col: anchor.startCol, row: row),
                    end: Position(col: anchor.endCol, row: row + anchor.rowSpan)))
            })
        switch landing {
        case .hold:
            kilterAnchor?.lastStartRow = selection.start.row
        case .move(let row):
            selection.setSelection(
                start: Position(col: anchor.startCol, row: row),
                end: Position(col: anchor.endCol, row: row + anchor.rowSpan))
            kilterAnchor?.lastStartRow = row
            requestDisplay()
        case .dormant:
            // The highlight goes away; the ANCHOR DOES NOT. This is the
            // whole of the owner's law — the words are off the glass, not
            // deselected, and they stand back up when they return.
            if selection.active {
                selection.selectNone()
                requestDisplay()
            }
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
        // `location(in: self)` on a UIScrollView is ALREADY content space
        // (bounds.origin carries the offset) — adding contentOffset again
        // was a latent double-shift, invisible on the shallow alt screen
        // where the offset sits at zero, wrong on a scrolled normal buffer.
        let content = point
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

    /// RIG ONLY — how the Metal row cache has actually behaved since this
    /// view was built: frames drawn, rows rebuilt, rows reused. Cumulative
    /// on purpose, so a probe samples once at each end of a drag and
    /// divides; an instantaneous gauge would sample a single frame and
    /// call it a scroll. `nil` when Metal is not the active renderer —
    /// the CoreGraphics path has no row cache to report on.
    var kilterMetalRowStats: (frames: Int, rebuilt: Int, cached: Int)? {
#if canImport(MetalKit)
        guard let renderer = metalRenderer else { return nil }
        return (renderer.kilterFramesBuilt,
                renderer.kilterRowsRebuilt,
                renderer.kilterRowsCached)
#else
        return nil
#endif
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