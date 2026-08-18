//
// KilterSelectionAnchorPolicy.swift — §1.8's law, as a pure rule.
//
// THE OWNER'S LAW (2026-08-13 night, dictated): *"the same behavior as
// any text on my iPhone — scroll anywhere, come back, still selected,
// extend whenever."*
//
// WHY THIS FILE EXISTS (2026-08-18). That law has been broken and
// re-fixed four times — builds 82, 83, 84, 86 — and every fix lived
// inside a UIKit extension that no test could reach. The owner's
// complaint this round was not the bug, it was the RECURRENCE: *"it was
// diagnosed and fixed before and it has come back."* A rule that only
// exists as guard clauses scattered through gesture handlers has no way
// to fail loudly, so it fails quietly instead, one renderer swap or one
// scroll rewrite at a time.
//
// So the decision is extracted here: pure, `Sendable`, no UIKit, and
// deliberately WITHOUT the `#if os(iOS)` guard the rest of kilter's
// additions carry — this file compiles on macOS, which is what lets
// kelter's `swift test` suite assert the owner's words directly
// (`Tests/Unit/SelectionAnchorPolicyTests.swift`).
//
// The UIKit side (`KilterAdditions.swift`) keeps the buffer reads and
// the repaint calls; every JUDGEMENT it used to make inline it now asks
// this file for.
//
import Foundation

/// §1.8 — what the user selected, anchored to CONTENT rather than to a
/// screen cell. On the alternate screen the remote repaints rows in
/// place, so a cell-anchored selection either dies (the pre-82
/// clear-on-scroll) or lies (the July wrong-text bug). This remembers
/// the TEXT with its line context so the view can re-find it after any
/// repaint.
public struct KilterSelectionAnchor: Equatable, Sendable {
    /// The full selected span, normalized (see `kilterNormalizedSpan`).
    public var text: String
    /// The first LINE of the selected text itself — the search needle.
    /// NOT the full terminal row: on a multi-pane TUI (herdr) the row
    /// also carries the rail beside the transcript, which does NOT move
    /// when the pane scrolls, so full-row matching only ever succeeded
    /// at the original position (owner walk 2026-08-14: *"you can see
    /// the sentence, but you cannot see the marking until you go
    /// back"*).
    public var firstSelLine: String
    public var startCol: Int
    public var endCol: Int
    public var rowSpan: Int
    /// Where the span last stood — the tiebreak when the needle matches
    /// more than one row (a repetitive transcript). Nearest wins.
    public var lastStartRow: Int

    public init(text: String, firstSelLine: String, startCol: Int,
                endCol: Int, rowSpan: Int, lastStartRow: Int) {
        self.text = text
        self.firstSelLine = firstSelLine
        self.startCol = startCol
        self.endCol = endCol
        self.rowSpan = rowSpan
        self.lastStartRow = lastStartRow
    }
}

/// Right-trim every line of a span. A handle-dragged selection almost
/// always swallows the gap AFTER a word (the end grabber sits past the
/// word boundary, iOS-style), so its captured text carries trailing
/// spaces — while the re-finder reads rows `trimRight`ed. One trailing
/// space failed the compare and the whole span was declared off screen:
/// a double-tapped word survived scrolling, a dragged sentence died
/// (owner walk 2026-08-14, build 87). Every anchor comparison goes
/// through this, on BOTH sides.
public func kilterNormalizedSpan(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> String in
            var s = line[...]
            while let last = s.last, last == " " || last == "\t" { s = s.dropLast() }
            return String(s)
        }
        .joined(separator: "\n")
}

/// Everything that has ever ASKED to change the anchor. Naming them is
/// the point: before this enum the same question was answered inline at
/// ten call sites in four files, in four different idioms, and each
/// re-fix only taught one of them.
public enum KilterAnchorEvent: Equatable, Sendable {
    /// The selection went inactive. Build 83's bug in one line: this
    /// arrives ASYNC, after the re-anchorer's guard flag has reset, so
    /// the dormancy's OWN `selectNone` came back looking like a user
    /// dismissal and erased the anchor it existed to protect.
    case selectionDeactivated
    /// The re-anchorer moved the highlight to its text. Not news.
    case reanchorerMovedIt
    /// A user gesture changed the selection — double-tap, long-press
    /// Select, drag-extend, handle drag, pencil. Synchronous, while the
    /// selected text is still the text under the highlight (build 86:
    /// capturing from the async notification instead froze the
    /// highlight at a screen position while the words slid underneath).
    case userGestureChangedSelection(onAlternateBuffer: Bool)
    /// The user dismissed it on purpose — the grid tap, on a still
    /// glass (build 84: a scroll flick's trailing touch lands as a tap,
    /// and dismissing on THAT threw selections away mid-read).
    case userDismissedDeliberately
    /// Reading mode took the glass; the grid's selection stands down.
    case readingModeEntered
    /// The host repainted under the highlight. Never news either — the
    /// whole point of anchoring to content is that a repaint is not a
    /// dismissal.
    case hostRepaint
}

/// What may happen to the anchor.
public enum KilterAnchorVerdict: Equatable, Sendable {
    /// The anchor lives, untouched. The DEFAULT, and the owner's law.
    case keep
    /// The anchor dies. Only a deliberate human dismissal earns this.
    case drop
    /// Re-read the selected text and replace the anchor with it.
    case recapture
}

/// Where the highlight belongs after a repaint.
public enum KilterAnchorLanding: Equatable, Sendable {
    /// Already sitting on its own text — nothing to do (the fast path).
    case hold
    /// Found whole, and verified: move the selection here.
    case move(startRow: Int)
    /// **HALF ON THE GLASS** (owner, 2026-08-18, build 121: *"if you
    /// scroll away from it — like three or four lines above it — it will
    /// disappear, even though a tiny bit of it should be shown. Until you
    /// go back to the same frame you were in before, then it's visible
    /// again."*)
    ///
    /// Only anchor lines `lines` are still on the glass. `startRow` is
    /// where line 0 WOULD sit, so the rows actually present are
    /// `startRow + lines.lowerBound ... startRow + lines.upperBound` —
    /// and `startRow` may be negative when the span's head is the half
    /// that scrolled away. Highlight what is there; the anchor keeps the
    /// whole span, so the rest comes back with it.
    case partial(startRow: Int, lines: ClosedRange<Int>)
    /// Not on the glass at all. The highlight goes away; **the anchor
    /// does not.** It comes back with its text.
    case dormant
}

/// §1.8's decisions, with nothing else attached.
public enum KilterAnchorPolicy {

    /// THE LAW: what an event does to the anchor.
    ///
    /// The default is `keep`, and that is not an implementation detail —
    /// it is the whole fix. Every recurrence of this bug has been some
    /// new code path discovering that it, too, could quietly drop the
    /// anchor. Here there is exactly one way to say `drop`, and it takes
    /// a deliberate human act to reach it.
    public static func verdict(for event: KilterAnchorEvent) -> KilterAnchorVerdict {
        switch event {
        case .userDismissedDeliberately, .readingModeEntered:
            return .drop
        case .userGestureChangedSelection(let onAlternateBuffer):
            // On the NORMAL buffer the selection's rows are
            // content-absolute and survive scrolling by construction, so
            // there is nothing to anchor and a stale anchor would only
            // lie. On the ALTERNATE screen the anchor is the mechanism.
            return onAlternateBuffer ? .recapture : .drop
        case .selectionDeactivated, .reanchorerMovedIt, .hostRepaint:
            return .keep
        }
    }

    /// THE SEARCH: given the anchor and a way to read the display
    /// buffer, where does the highlight re-land?
    ///
    /// Pure by construction — the two closures are the only contact with
    /// the terminal, so every branch is reachable from a test.
    ///
    /// LINE BY LINE, NOT ALL-OR-NOTHING (owner, 2026-08-18). This used to
    /// verify the whole span with one `getText` compare and return
    /// `dormant` on any mismatch — so a sentence straddling the edge of
    /// what the terminal still holds lost its VISIBLE half too, and only
    /// came back when the original frame did. Each anchor line is now
    /// matched against its own row at its own column, and the highlight
    /// covers the longest contiguous run that is genuinely there. The
    /// full-span verification is kept for the whole-span case, because
    /// that is the July wrong-text lock.
    ///
    /// - Parameters:
    ///   - anchor: the span to find.
    ///   - activeSpan: the text under the CURRENT selection, or nil when
    ///     no selection is active.
    ///   - rowCount: rows in the display buffer.
    ///   - rowText: (row, startCol) → that row's text from `startCol`
    ///     rightward, right-trimmed. Searching by the SELECTED TEXT at
    ///     its own column (not the full row) is what makes this survive
    ///     herdr's static rail — the thing beside the pane does not move
    ///     when the pane scrolls, and full-row equality only ever matched
    ///     at the original position.
    ///   - spanText: candidate start row → the full normalized span that
    ///     would be selected there. The verification gate for a whole
    ///     span: a candidate that does not reproduce the anchor's text
    ///     EXACTLY is refused, which is why the July wrong-text bug
    ///     cannot recur.
    public static func locate(
        anchor: KilterSelectionAnchor,
        activeSpan: String?,
        rowCount: Int,
        rowText: (_ row: Int, _ startCol: Int) -> String,
        spanText: (_ startRow: Int) -> String
    ) -> KilterAnchorLanding {
        // Fast path: the highlight is already on its words.
        if let activeSpan, activeSpan == anchor.text { return .hold }
        guard rowCount > 0 else { return .dormant }

        let lines = anchor.text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let lastLine = anchor.rowSpan
        guard lines.count == lastLine + 1 else { return .dormant }

        /// Which column anchor line `i` begins at: the first line starts
        /// where the user's selection started, every later line at the
        /// left edge of the row.
        func column(_ i: Int) -> Int { i == 0 ? anchor.startCol : 0 }

        func matches(line i: Int, atRow row: Int) -> Bool {
            guard row >= 0, row < rowCount else { return false }
            // A BLANK LINE INSIDE THE SPAN IS STILL PART OF IT. A selected
            // paragraph routinely contains empty rows (any transcript
            // does), and `hasPrefix("")` is true of everything — so an
            // empty anchor line must match an empty ROW, exactly, or the
            // run would stop dead at the first blank and clip a paragraph
            // the user can plainly see whole.
            if lines[i].isEmpty { return rowText(row, column(i)).isEmpty }
            return rowText(row, column(i)).hasPrefix(lines[i])
        }

        /// A blank line is not a needle — every blank row matches it, so
        /// it can never tell us WHERE the span sits. Only a line with
        /// content may seed the search; blanks are picked up afterwards,
        /// when the run grows outward from a line that is distinctive.
        func canSeed(_ i: Int) -> Bool { !lines[i].isEmpty }

        // Find where line 0 WOULD sit. Try the anchor's own first line
        // first — the original needle, and the common case. If the span's
        // head is the half that scrolled away, fall back to the first
        // later line that is still on the glass and work backwards.
        var startRow: Int?
        var seedLine = 0
        for i in 0...lastLine {
            guard canSeed(i) else { continue }
            var best: Int?
            var row = 0
            while row < rowCount {
                defer { row += 1 }
                guard matches(line: i, atRow: row) else { continue }
                // Nearest to where it last stood wins — a transcript
                // repeats itself, and the honest tiebreak is "the one
                // closest to where the reader's eyes were". Documented
                // heuristic, not a guarantee.
                let candidate = row - i
                if let b = best,
                   abs(b - anchor.lastStartRow) <= abs(candidate - anchor.lastStartRow) { continue }
                best = candidate
            }
            if let best {
                startRow = best
                seedLine = i
                break
            }
        }
        guard let startRow else { return .dormant }

        // Grow the run outward from the line we actually found.
        var lower = seedLine, upper = seedLine
        while lower > 0, matches(line: lower - 1, atRow: startRow + lower - 1) { lower -= 1 }
        while upper < lastLine, matches(line: upper + 1, atRow: startRow + upper + 1) { upper += 1 }

        if lower == 0 && upper == lastLine {
            // The whole span is here — the July lock still gates it.
            guard spanText(startRow) == anchor.text else { return .dormant }
            return .move(startRow: startRow)
        }
        return .partial(startRow: startRow, lines: lower...upper)
    }
}

