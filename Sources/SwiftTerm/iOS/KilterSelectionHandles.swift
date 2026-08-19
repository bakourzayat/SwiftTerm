//
// KilterSelectionHandles.swift — grabbable ends for a terminal selection.
//
// WHY THIS EXISTS (owner, 2026-08-10: "you can only select one word, you
// cannot drag the selection… we want it to be touch friendly, which means you
// can grab the end of it and drag it up or down and the page will scroll").
//
// The gesture machinery was never the bug. `panSelectionHandler` seeds the
// pivot on every drag, `pivotExtend` runs on movement, and the edge
// auto-scroll works. What was missing is a THING TO GRAB: extending required
// landing within 3 columns and 2 rows of an endpoint (`near()`), with nothing
// drawn to show where that was. On a touch screen that is an invisible few
// millimetres, so in practice the selection could not be dragged at all.
//
// These are UIViews rather than something painted in `draw(_:)` for three
// reasons: `draw` returns early under the Metal renderer, so painted handles
// could silently vanish; a view gets real hit-testing for free; and a view can
// be VISUALLY small while being 44pt to a finger, which is the whole point.
//
#if os(iOS) || os(visionOS)
import UIKit

/// One draggable end. The dot is cosmetic; the view itself is the touch target.
final class KilterSelectionHandleView: UIView {
    /// Apple's minimum comfortable target. The visible dot is far smaller —
    /// the generous part is deliberately invisible.
    static let touchSize: CGFloat = 44
    static let dotSize: CGFloat = 12

    /// True for the handle sitting at `selection.start`.
    let isStart: Bool
    private let dot = CALayer()

    init(isStart: Bool, color: UIColor) {
        self.isStart = isStart
        super.init(frame: CGRect(x: 0, y: 0, width: Self.touchSize, height: Self.touchSize))
        backgroundColor = .clear
        isUserInteractionEnabled = true
        dot.backgroundColor = color.cgColor
        dot.cornerRadius = Self.dotSize / 2
        dot.frame = CGRect(x: (Self.touchSize - Self.dotSize) / 2,
                           y: (Self.touchSize - Self.dotSize) / 2,
                           width: Self.dotSize, height: Self.dotSize)
        // A hairline ring keeps the dot visible on a background that happens
        // to be the same blue.
        dot.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
        dot.borderWidth = 1
        layer.addSublayer(dot)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    func setColor(_ color: UIColor) { dot.backgroundColor = color.cgColor }

    /// The whole 44pt square is grabbable, not just the drawn dot.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.contains(point)
    }
}
#endif

#if os(iOS) || os(visionOS)
import UIKit

public extension TerminalView {

    // MARK: Grabbable selection ends (kilter, 2026-08-10)

    /// Show/refresh the handles for the live selection, or remove them when
    /// there is nothing selected. Safe to call on every selection change and
    /// every layout pass.
    func kilterUpdateSelectionHandles() {
        guard kilterHandlesEnabled else { kilterRemoveSelectionHandles(); return }
        guard selection.active else { kilterRemoveSelectionHandles(); return }

        let start = kilterEnsureHandle(isStart: true)
        let end = kilterEnsureHandle(isStart: false)
        // Content-space, exactly like `kilterSelectionEndRect`: the view is a
        // UIScrollView whose content already carries the scroll offset, so a
        // handle placed here tracks the TEXT, not the glass.
        let cw = cellDimension.width, ch = cellDimension.height
        // The start grabber sits at the leading edge of the first cell; the end
        // grabber at the trailing edge of the last — the way iOS frames a range.
        start.center = CGPoint(x: CGFloat(selection.start.col) * cw,
                               y: CGFloat(selection.start.row) * ch + ch / 2)
        end.center = CGPoint(x: CGFloat(selection.end.col) * cw + cw,
                             y: CGFloat(selection.end.row) * ch + ch / 2)
        bringSubviewToFront(start)
        bringSubviewToFront(end)
    }

    func kilterRemoveSelectionHandles() {
        for v in subviews.compactMap({ $0 as? KilterSelectionHandleView }) {
            v.removeFromSuperview()
        }
        kilterStopHandleAutoScroll()
    }

    private func kilterEnsureHandle(isStart: Bool) -> KilterSelectionHandleView {
        if let existing = subviews.compactMap({ $0 as? KilterSelectionHandleView })
            .first(where: { $0.isStart == isStart }) {
            existing.setColor(selectionHandleColor)
            return existing
        }
        let h = KilterSelectionHandleView(isStart: isStart, color: selectionHandleColor)
        let pan = UIPanGestureRecognizer(target: self,
                                         action: #selector(kilterHandlePan(_:)))
        // The handle owns its own touch outright: no competing recognizer on
        // the grid should get a say once a finger is on a grabber.
        pan.cancelsTouchesInView = true
        h.addGestureRecognizer(pan)
        addSubview(h)
        return h
    }

    /// Drag a grabber: the OPPOSITE end becomes the pivot, so the end under the
    /// finger is the one that moves — which is what grabbing an end means.
    @objc private func kilterHandlePan(_ g: UIPanGestureRecognizer) {
        guard let handle = g.view as? KilterSelectionHandleView, selection.active else { return }
        let point = g.location(in: self)

        switch g.state {
        case .began:
            selection.pivot = handle.isStart ? selection.end : selection.start
            kilterActiveHandlePan = g
            kilterActiveHandleIsStart = handle.isStart
            // A FINGER ON A GRABBER OWNS THE SELECTION until it lifts —
            // it alone may make the passage smaller (owner 2026-08-19).
            kilterFingerOwnsSelection = true
            kilterSeedPivotNeedle(draggingStart: handle.isStart)
        case .changed:
            // While the edge ticker scrolls the remote, the content under
            // the span is MID-FLIGHT — the tick owns extension and nothing
            // captures (§1.9 round 2: a capture here read half-painted
            // text, poisoned the anchor, and the selection "disappeared
            // completely" one tick into the scroll). Inside the glass this
            // is the plain settled path it always was.
            if !kilterEdgeDragActive {
                let hit = calculateTapHit(point: point).grid
                selection.pivotExtend(bufferPosition: hit)
                kilterCaptureSelectionAnchor()   // §1.8: the finger is the truth
                kilterUpdateSelectionHandles()
                requestDisplay()
            }
            // THE PAGE SCROLLS WITH THE FINGER (his ask). Dragging past either
            // edge of the visible area keeps the selection growing instead of
            // stopping dead at the boundary — the ticker below does the work,
            // because a finger HELD at the edge emits no more .changed events.
            if kilterEdgeOvershoot(at: point) != nil {
                kilterStartHandleAutoScroll()
            } else {
                kilterStopHandleAutoScroll()
            }
        case .ended, .cancelled, .failed:
            kilterStopHandleAutoScroll()
            kilterActiveHandlePan = nil
            // The paint settles at release — NOW the anchor learns the
            // final span, once, whole. The finger still owns it for this
            // one capture; it lets go immediately after.
            kilterCaptureSelectionAnchor()
            kilterFingerOwnsSelection = false
            kilterUpdateSelectionHandles()
            // Apple's grammar (owner 2026-08-14: "once you release your
            // finger, it shows you back again"): release = the verbs
            // re-hang on the selection.
            if selection.active {
                showContextMenu(forRegion: makeContextMenuRegionForSelection(),
                                pos: selection.end)
            }
        default:
            break
        }
    }

    /// §1.9 round 2 — pin the PIVOT end to its own line of text for the
    /// duration of an edge drag: the far end follows its LINE through
    /// repaints, the near end follows the finger, and the full-span
    /// anchor is written only at release.
    func kilterSeedPivotNeedle(draggingStart: Bool) {
        let t = getTerminal()
        let s = selection.start, e = selection.end
        let text = kilterNormalizedSpan(t.getText(start: s, end: e))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if draggingStart {
            // Pivot = selection END: its needle is the span's LAST line,
            // which starts at col 0 on a multi-row span.
            kilterPivotNeedle = String(lines.last ?? "")
            kilterPivotNeedleCol = s.row == e.row ? s.col : 0
            kilterPivotEdgeCol = e.col
            kilterPivotLastRow = e.row
        } else {
            kilterPivotNeedle = String(lines.first ?? "")
            kilterPivotNeedleCol = s.col
            kilterPivotEdgeCol = s.col
            kilterPivotLastRow = s.row
        }
    }

    /// One edge-drag step: re-find the pivot line near where it last
    /// stood, re-seat the pivot there, extend to the finger. No capture —
    /// the content is mid-flight until release.
    func kilterEdgeDragExtend(to point: CGPoint) {
        guard selection.active else { return }
        let t = getTerminal()
        let buffer = t.displayBuffer
        let rows = buffer.lines.count
        var best: Int?
        if !kilterPivotNeedle.isEmpty {
            for row in 0..<rows {
                let tail = buffer.lines[row].translateToString(
                    trimRight: true, startCol: kilterPivotNeedleCol)
                guard tail.hasPrefix(kilterPivotNeedle) else { continue }
                if let b = best,
                   abs(b - kilterPivotLastRow) <= abs(row - kilterPivotLastRow) { continue }
                best = row
            }
        }
        // Needle off screen (the drag out-ran a full page): hold the last
        // known row, clamped — the selection reaches the screen edge and
        // keeps growing on the finger side.
        let pivotRow = min(max(0, best ?? kilterPivotLastRow), max(0, rows - 1))
        kilterPivotLastRow = pivotRow
        kilterReanchoring = true
        defer { kilterReanchoring = false }
        selection.pivot = Position(col: kilterPivotEdgeCol, row: pivotRow)
        selection.pivotExtend(bufferPosition: calculateTapHit(point: point).grid)
        kilterUpdateSelectionHandles()
        requestDisplay()
    }

    // MARK: §1.9 rig hooks — drive the EXACT edge-drag path headlessly
    // (owner 2026-08-14: "it'll be nice if we can create something that we
    // can test on" — simctl cannot drag, so the rig calls what the finger
    // calls).

    public func kilterDebugEdgeDragBegin(draggingStart: Bool) {
        guard selection.active else { return }
        selection.pivot = draggingStart ? selection.end : selection.start
        kilterActiveHandleIsStart = draggingStart
        kilterFingerOwnsSelection = true
        kilterSeedPivotNeedle(draggingStart: draggingStart)
        kilterEdgeDragActive = true
    }

    public func kilterDebugEdgeDragTick(at point: CGPoint) {
        guard kilterEdgeDragActive else { return }
        if let over = kilterEdgeOvershoot(at: point) {
            let steps = min(4, 1 + Int(over.distance / 30))
            kilterEdgeScroll?(over.up, steps, point)
        }
        kilterEdgeDragExtend(to: point)
    }

    public func kilterDebugEdgeDragEnd() {
        kilterEdgeDragActive = false
        kilterCaptureSelectionAnchor()
        kilterFingerOwnsSelection = false
    }

    /// How far past the scroll threshold the finger sits, in GLASS space —
    /// nil inside the comfortable zone. Distance drives the speed ramp
    /// (owner 2026-08-14: "as much as we're going up, the speed of the
    /// scrolling is going up").
    private func kilterEdgeOvershoot(at point: CGPoint) -> (up: Bool, distance: CGFloat)? {
        let visibleY = point.y - contentOffset.y
        let edge = cellDimension.height
        if visibleY < edge { return (true, edge - visibleY) }
        if visibleY > bounds.height - edge { return (false, visibleY - (bounds.height - edge)) }
        return nil
    }

    /// §1.9 — the edge ticker. Each tick: scroll one-to-four lines (speed ∝
    /// overshoot) through the embedder's router — LOCAL scrollback where the
    /// page owns history, WHEEL EVENTS to the remote TUI (herdr) where it
    /// doesn't, which is what lets a drag reach text that was never on the
    /// glass — then run one pivot-tracked extend (`kilterEdgeDragExtend`).
    /// While the ticker is alive, `kilterEdgeDragActive` suspends the
    /// re-anchorer and NOTHING captures: the content is mid-flight, and
    /// capturing it poisoned the anchor (owner walk of 87).
    private func kilterStartHandleAutoScroll() {
        guard kilterHandleAutoScrollTimer == nil else { return }
        kilterEdgeDragActive = true
        let t = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let g = self.kilterActiveHandlePan,
                      g.state == .began || g.state == .changed,
                      self.selection.active else {
                    self.kilterStopHandleAutoScroll()
                    return
                }
                let point = g.location(in: self)
                guard let over = self.kilterEdgeOvershoot(at: point) else {
                    self.kilterStopHandleAutoScroll()
                    return
                }
                let steps = min(4, 1 + Int(over.distance / 30))
                if let route = self.kilterEdgeScroll {
                    route(over.up, steps, point)
                } else {
                    let maxY = max(0, self.contentSize.height - self.bounds.height)
                    let dy = self.cellDimension.height * CGFloat(steps)
                    let y = min(maxY, max(0, self.contentOffset.y + (over.up ? -dy : dy)))
                    self.contentOffset = CGPoint(x: self.contentOffset.x, y: y)
                }
                self.kilterEdgeDragExtend(to: g.location(in: self))
            }
        }
        kilterHandleAutoScrollTimer = t
    }

    private func kilterStopHandleAutoScroll() {
        kilterHandleAutoScrollTimer?.invalidate()
        kilterHandleAutoScrollTimer = nil
        kilterEdgeDragActive = false
    }
}
#endif
