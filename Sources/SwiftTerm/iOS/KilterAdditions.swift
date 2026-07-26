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
}
#endif