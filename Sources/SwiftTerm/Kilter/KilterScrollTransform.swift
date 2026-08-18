//
// KilterScrollTransform.swift — where the scroll position lives.
//
// THE RULE, ONE SENTENCE: a scroll is a TRANSLATION of the picture, never
// a change to the picture's contents.
//
// The Metal renderer caches per-row GPU vertices and reuses them until a
// row's TEXT changes. On 2026-08-17 the sub-row scroll remainder was
// folded into the cache's signature (`CacheSignature.subRowOffsetPx`) so
// that "cached vertices cannot be reused across a different fraction of a
// row" — true of vertices built at absolute screen positions, and the
// reason the cache was then destroyed on EVERY frame of a pixel-smooth
// scroll: ~45 rows rebuilt and ~180 un-pooled `MTLBuffer` allocations per
// frame, ~2,700 rebuilds/second at 60 Hz. That is the exact per-frame cost
// the Metal renderer was adopted to escape.
//
// The remainder is not content. Neither is the whole-row part of the
// scroll: both are the same one number — where the viewport sits in the
// content — and both belong in the vertex transform. So rows are built
// once, relative to an ANCHOR row, and the difference between the anchor
// and the live scroll position rides to the GPU as a per-frame uniform.
// Constant content ⇒ the cache survives frame after frame; the only rows
// that ever rebuild are the ones whose text actually changed and the one
// or two entering the glass at the edge.
//
// Pure arithmetic on purpose, and platform-free, so the invariant can be
// asserted for every scroll position rather than for the two the
// simulator happened to produce — the pattern `TerminalGridFit` and
// `KilterSelectionAnchorPolicy` already set in this repo.
//
import Foundation

/// Which rows the glass shows, and how far the whole picture must slide.
public struct KilterScrollLayout: Equatable {
    /// First buffer row with any pixel on the glass.
    public let firstRow: Int
    /// Last buffer row with any pixel on the glass — INCLUSIVE of the
    /// partially-visible row at the bottom (see `KilterScrollTransform`).
    public let lastRow: Int
    /// The whole-picture slide, in DEVICE PIXELS, in the renderer's Y-UP
    /// vertex space: add it to every vertex's y. Positive means the
    /// content moves UP the glass, which is what scrolling DOWN looks
    /// like. Zero exactly when the viewport sits on the anchor row's
    /// boundary, so a still terminal renders byte-identically to the
    /// pre-2026-08-17 renderer.
    public let translateYPx: Double
}

public enum KilterScrollTransform {
    /// How far the anchor may drift from the live first row before the
    /// cache is re-anchored (and, necessarily, rebuilt once).
    ///
    /// Row vertices are `Float`, whose mantissa holds integers exactly to
    /// 2^24 ≈ 16.7 M. A row this many rows from the anchor sits at
    /// |y| ≈ 4096 × cellHeight × scale ≈ 300 K device pixels — two orders
    /// of magnitude inside the exact range, so the translation is lossless
    /// and the picture cannot creep. Crossing 4096 rows takes many seconds
    /// of continuous scrolling, and costs exactly one rebuilt frame.
    public static let maxAnchorDrift = 4096

    /// Snap a scroll position to a whole device pixel. Below a pixel there
    /// is nothing to paint, and an unsnapped offset would make every
    /// glyph's `round()` land on a different sub-pixel phase.
    public static func quantise(scrollY: Double, scale: Double) -> Double {
        let s = max(scale, 1)
        return (scrollY * s).rounded() / s
    }

    /// True when the anchor is too far from where we are now to keep
    /// translating from it. The caller must then wipe the row cache and
    /// re-anchor — the two go together or cached rows would be drawn at
    /// the wrong offset.
    public static func needsReanchor(firstRow: Int, anchorRow: Int) -> Bool {
        return abs(firstRow - anchorRow) > maxAnchorDrift
    }

    /// The visible range and the frame's translation.
    ///
    /// - Parameters:
    ///   - scrollY: the viewport's top in CONTENT points, unclamped.
    ///   - viewHeight: the glass, in points.
    ///   - cellHeight: one text row, in points — the renderer's own
    ///     `cellDimension.height`, already pixel-snapped.
    ///   - lineCount: rows in the buffer, scrollback included.
    ///   - scale: the backing scale factor.
    ///   - anchorRow: the row the cached vertices were built against.
    /// - Returns: `nil` when there is nothing to draw.
    public static func layout(scrollY: Double,
                              viewHeight: Double,
                              cellHeight: Double,
                              lineCount: Int,
                              scale: Double,
                              anchorRow: Int) -> KilterScrollLayout? {
        guard lineCount > 0, cellHeight > 0, viewHeight > 0 else { return nil }
        let contentHeight = Double(lineCount) * cellHeight
        let maxOffset = max(0, contentHeight - viewHeight)
        let clamped = min(max(0, scrollY), maxOffset)
        let offsetY = quantise(scrollY: clamped, scale: scale)
        let firstRow = max(0, Int((offsetY / cellHeight).rounded(.down)))
        // One row further than a floor()-of-the-bottom-edge would give:
        // with a sub-row offset the bottom row is partially visible and
        // its glyphs must exist, or the smooth shift exposes a blank strip
        // as it slides up. (KILTER 2026-08-17, kept verbatim.)
        let lastRow = min(lineCount - 1, Int(((offsetY + viewHeight) / cellHeight).rounded(.down)))
        guard firstRow <= lastRow else { return nil }
        // Rows are built at `cellHeight * (row - anchorRow + 1)` from the
        // top; the picture they belong to is at `cellHeight * (row + 1) -
        // offsetY`. The difference is the same for every row — which is
        // the whole point — and it is this:
        let translatePt = offsetY - Double(anchorRow) * cellHeight
        return KilterScrollLayout(firstRow: firstRow,
                                  lastRow: lastRow,
                                  translateYPx: (translatePt * scale).rounded())
    }
}
