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
        case .changed:
            let hit = calculateTapHit(point: point).grid
            selection.pivotExtend(bufferPosition: hit)
            kilterCaptureSelectionAnchor()   // §1.8: the finger is the truth
            kilterUpdateSelectionHandles()
            requestDisplay()
            // THE PAGE SCROLLS WITH THE FINGER (his ask). Dragging past either
            // edge of the visible area keeps the selection growing instead of
            // stopping dead at the boundary.
            let visibleY = point.y - contentOffset.y
            if visibleY < cellDimension.height || visibleY > bounds.height - cellDimension.height {
                kilterStartHandleAutoScroll(up: visibleY < cellDimension.height)
            } else {
                kilterStopHandleAutoScroll()
            }
        case .ended, .cancelled, .failed:
            kilterStopHandleAutoScroll()
            kilterUpdateSelectionHandles()
        default:
            break
        }
    }

    private func kilterStartHandleAutoScroll(up: Bool) {
        guard kilterHandleAutoScrollTimer == nil else { return }
        let step = cellDimension.height * 2
        let t = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let maxY = max(0, self.contentSize.height - self.bounds.height)
                let y = min(maxY, max(0, self.contentOffset.y + (up ? -step : step)))
                self.contentOffset = CGPoint(x: self.contentOffset.x, y: y)
            }
        }
        kilterHandleAutoScrollTimer = t
    }

    private func kilterStopHandleAutoScroll() {
        kilterHandleAutoScrollTimer?.invalidate()
        kilterHandleAutoScrollTimer = nil
    }
}
#endif
