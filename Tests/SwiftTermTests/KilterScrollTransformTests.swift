//
// KilterScrollTransformTests.swift
//
// The row cache's claim is *"a visible row's GPU vertices may be reused
// until that row's text changes."* From 2026-08-17 to 2026-08-18 that
// claim was false: the sub-row scroll remainder sat in the cache key, so
// a pixel-smooth scroll rebuilt every visible row on every frame. The
// decision was untestable because it was buried in a 200-line method.
// These tests pin the extracted rule.
//
import XCTest
@testable import SwiftTerm

final class KilterScrollTransformTests: XCTestCase {
    // An iPad-ish grid: 20 pt rows, @2x, a tall glass, deep scrollback.
    private let cell = 20.0
    private let glass = 900.0
    private let scale = 2.0
    private let lines = 5_000

    private func layout(_ scrollY: Double, anchor: Int) -> KilterScrollLayout? {
        KilterScrollTransform.layout(scrollY: scrollY,
                                     viewHeight: glass,
                                     cellHeight: cell,
                                     lineCount: lines,
                                     scale: scale,
                                     anchorRow: anchor)
    }

    // MARK: - the finding this file exists for

    /// THE LOCK. A sub-row offset change alone rebuilds ZERO rows: the
    /// visible range and the anchor are untouched, so every cached row is
    /// still valid, and only the translation moves.
    func test_a_sub_row_move_changes_only_the_translation() throws {
        let anchor = 100
        let a = try XCTUnwrap(layout(2_000.0, anchor: anchor))          // on a row boundary
        let b = try XCTUnwrap(layout(2_000.0 + 3.5, anchor: anchor))    // 3.5 pt later
        XCTAssertEqual(a.firstRow, b.firstRow)
        XCTAssertEqual(a.lastRow, b.lastRow)
        XCTAssertNotEqual(a.translateYPx, b.translateYPx)
        XCTAssertEqual(b.translateYPx - a.translateYPx, 7.0)  // 3.5 pt @2x
    }

    /// And the same holds across a WHOLE row: crossing a line boundary
    /// moves the translation by exactly one cell, not the geometry.
    func test_crossing_a_row_boundary_changes_only_the_translation() throws {
        let anchor = 100
        let a = try XCTUnwrap(layout(2_000.0, anchor: anchor))
        let b = try XCTUnwrap(layout(2_000.0 + cell, anchor: anchor))
        XCTAssertEqual(b.firstRow, a.firstRow + 1)
        XCTAssertEqual(b.lastRow, a.lastRow + 1)
        XCTAssertEqual(b.translateYPx - a.translateYPx, cell * scale)
    }

    /// Every frame of a full row of pixel-smooth travel: the anchor never
    /// moves, so the cache never needs wiping — the whole point.
    func test_a_pixel_smooth_row_of_travel_never_needs_a_new_anchor() {
        let anchor = 100
        var previous = -Double.infinity
        for step in 0...120 {
            let scrollY = 2_000.0 + Double(step) * (cell / 120.0)
            guard let l = layout(scrollY, anchor: anchor) else { return XCTFail("no layout") }
            XCTAssertFalse(KilterScrollTransform.needsReanchor(firstRow: l.firstRow,
                                                               anchorRow: anchor))
            XCTAssertGreaterThanOrEqual(l.translateYPx, previous)   // monotone, no jitter
            previous = l.translateYPx
        }
    }

    // MARK: - the translation itself

    func test_sitting_on_the_anchor_translates_by_nothing() throws {
        let l = try XCTUnwrap(layout(100.0 * cell, anchor: 100))
        XCTAssertEqual(l.translateYPx, 0)
        XCTAssertEqual(l.firstRow, 100)
    }

    /// Translation is whole device pixels: below one there is nothing to
    /// paint, and an unsnapped offset would put every glyph's `round()`
    /// on a different sub-pixel phase.
    func test_the_translation_is_whole_device_pixels() throws {
        for hundredths in 0...100 {
            let l = try XCTUnwrap(layout(2_000.0 + Double(hundredths) / 100.0, anchor: 100))
            XCTAssertEqual(l.translateYPx, l.translateYPx.rounded(), accuracy: 0)
        }
    }

    // MARK: - the visible range

    /// `56666e7`'s partially-visible bottom row must survive the fix: the
    /// range covers one row past the last whole one, or the smooth shift
    /// exposes a blank strip as it slides up.
    func test_a_part_row_at_the_bottom_is_still_drawn() throws {
        let whole = try XCTUnwrap(layout(2_000.0, anchor: 0))
        XCTAssertEqual(whole.firstRow, 100)
        // 900 pt of glass over 20 pt rows = 45 whole rows: 100...144. The
        // 46th row is the one the slide will expose.
        XCTAssertEqual(whole.lastRow, 145)
        let part = try XCTUnwrap(layout(2_000.0 + 1.0, anchor: 0))
        XCTAssertEqual(part.firstRow, 100)
        XCTAssertEqual(part.lastRow, 145)
    }

    func test_the_range_is_clamped_to_the_buffer() throws {
        let top = try XCTUnwrap(layout(-500.0, anchor: 0))
        XCTAssertEqual(top.firstRow, 0)
        XCTAssertEqual(top.translateYPx, 0)
        let bottom = try XCTUnwrap(layout(1_000_000.0, anchor: 0))
        XCTAssertEqual(bottom.lastRow, lines - 1)
    }

    func test_an_empty_buffer_draws_nothing() {
        XCTAssertNil(KilterScrollTransform.layout(scrollY: 0, viewHeight: glass,
                                                  cellHeight: cell, lineCount: 0,
                                                  scale: scale, anchorRow: 0))
        XCTAssertNil(KilterScrollTransform.layout(scrollY: 0, viewHeight: glass,
                                                  cellHeight: 0, lineCount: 10,
                                                  scale: scale, anchorRow: 0))
        XCTAssertNil(KilterScrollTransform.layout(scrollY: 0, viewHeight: 0,
                                                  cellHeight: cell, lineCount: 10,
                                                  scale: scale, anchorRow: 0))
    }

    // MARK: - the anchor's reach

    func test_the_anchor_holds_for_a_long_scroll_and_then_gives_way() {
        XCTAssertFalse(KilterScrollTransform.needsReanchor(firstRow: 0, anchorRow: 0))
        XCTAssertFalse(KilterScrollTransform.needsReanchor(firstRow: 4_096, anchorRow: 0))
        XCTAssertFalse(KilterScrollTransform.needsReanchor(firstRow: 0, anchorRow: 4_096))
        XCTAssertTrue(KilterScrollTransform.needsReanchor(firstRow: 4_097, anchorRow: 0))
        XCTAssertTrue(KilterScrollTransform.needsReanchor(firstRow: 0, anchorRow: 4_097))
    }

    /// Within the anchor's reach every coordinate the GPU sees is an exact
    /// `Float` — the reason the reach is bounded at all.
    func test_within_reach_the_coordinates_are_exact_in_float() throws {
        let anchor = 0
        let far = Double(KilterScrollTransform.maxAnchorDrift) * cell
        let l = try XCTUnwrap(layout(far, anchor: anchor))
        let builtRowY = -cell * Double(l.lastRow - anchor + 1) * scale
        XCTAssertEqual(Double(Float(builtRowY)), builtRowY)
        XCTAssertEqual(Double(Float(l.translateYPx)), l.translateYPx)
        XCTAssertEqual(Double(Float(builtRowY) + Float(l.translateYPx)),
                       builtRowY + l.translateYPx)
    }

    // MARK: - macOS's whole-line scrolling is the same rule

    func test_whole_line_scrolling_is_the_same_rule() throws {
        for yDisp in [0, 1, 7, 400] {
            let l = try XCTUnwrap(layout(Double(yDisp) * cell, anchor: yDisp))
            XCTAssertEqual(l.firstRow, yDisp)
            XCTAssertEqual(l.translateYPx, 0)
        }
    }
}
