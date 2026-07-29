//
//  MacExtensions.swift
//
//
//  Created by Miguel de Icaza on 6/29/21.
//

#if os(macOS)
import Foundation
import AppKit

extension NSColor {

    /// KILTER — guarantee a minimum perceived-luminance distance from
    /// `background`. See `KilterContrast` for why this exists.
    ///
    /// Walks the colour toward white or black — whichever side the background
    /// leaves room on — until it clears the floor. A dark panel therefore
    /// gets LIGHTER text and a light page gets DARKER text, which is what a
    /// reader expects and what a program that guessed wrong failed to do.
    /// Returns self untouched when the pair is already far enough apart, so
    /// a palette that was designed properly is never second-guessed.
    func kilterContrasted (against background: NSColor, minimum: CGFloat) -> NSColor {
        guard minimum > 0 else { return self }
        var fR: CGFloat = 0, fG: CGFloat = 0, fB: CGFloat = 0, fA: CGFloat = 1
        var bR: CGFloat = 0, bG: CGFloat = 0, bB: CGFloat = 0, bA: CGFloat = 1
        (self.usingColorSpace(.deviceRGB) ?? self).getRed(&fR, green: &fG, blue: &fB, alpha: &fA)
        (background.usingColorSpace(.deviceRGB) ?? background).getRed(&bR, green: &bG, blue: &bB, alpha: &bA)
        // Rec. 709 luma on the encoded values. Not colour science — a cheap,
        // stable ordering, which is all a threshold needs.
        func luma (_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
            0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        let fl = luma (fR, fG, fB)
        let bl = luma (bR, bG, bB)
        guard abs (fl - bl) < minimum else { return self }
        // Push AWAY from the background, toward whichever extreme is further
        // from it — so text on a dark block goes white, text on a light page
        // goes black, and neither ever crosses the background on the way.
        let target = bl < 0.5 ? min (1, bl + minimum) : max (0, bl - minimum)
        let extreme: CGFloat = target > fl ? 1 : 0
        let span = extreme - fl
        guard abs (span) > 0.0001 else { return self }
        let t = max (0, min (1, (target - fl) / span))
        func mix (_ c: CGFloat) -> CGFloat { c + (extreme - c) * t }
        return NSColor (red: mix (fR), green: mix (fG), blue: mix (fB), alpha: fA)
    }

    private static let srgbColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func getTerminalColor () -> Color {
        guard let color = self.usingColorSpace(.sRGB) else {
            return Color.defaultForeground
        }

        var red: CGFloat = 0.0, green: CGFloat = 0.0, blue: CGFloat = 0.0, alpha: CGFloat = 1.0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return Color(red: UInt16(red*65535), green: UInt16(green*65535), blue: UInt16(blue*65535))
    }
    func inverseColor() -> NSColor {
        guard let color = self.usingColorSpace(.sRGB) else {
            return self
        }

        var red: CGFloat = 0.0, green: CGFloat = 0.0, blue: CGFloat = 0.0, alpha: CGFloat = 1.0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let cg = CGColor(colorSpace: Self.srgbColorSpace, components: [1.0 - red, 1.0 - green, 1.0 - blue, alpha])!
        return NSColor(cgColor: cg)!
    }

    /// Returns a dimmed version of the color (SGR 2 faint/dim attribute) by
    /// blending 50 % toward `background`. The result is fully opaque so that
    /// adjacent box-drawing characters tile without visible seams.
    func dimmedColor (towards background: NSColor) -> NSColor {
        guard let fg = self.usingColorSpace(.sRGB),
              let bg = background.usingColorSpace(.sRGB) else {
            return self
        }
        var fRed: CGFloat = 0.0, fGreen: CGFloat = 0.0, fBlue: CGFloat = 0.0, fAlpha: CGFloat = 1.0
        fg.getRed(&fRed, green: &fGreen, blue: &fBlue, alpha: &fAlpha)
        var bRed: CGFloat = 0.0, bGreen: CGFloat = 0.0, bBlue: CGFloat = 0.0, bAlpha: CGFloat = 1.0
        bg.getRed(&bRed, green: &bGreen, blue: &bBlue, alpha: &bAlpha)
        let cg = CGColor(colorSpace: Self.srgbColorSpace,
                         components: [(fRed + bRed) * 0.5, (fGreen + bGreen) * 0.5, (fBlue + bBlue) * 0.5, fAlpha])!
        return NSColor(cgColor: cg)!
    }

    static func make (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) -> NSColor
    {
        let cg = CGColor(colorSpace: srgbColorSpace, components: [red, green, blue, alpha])!
        return NSColor(cgColor: cg)!
    }

    static func make (hue: CGFloat, saturation: CGFloat, brightness: CGFloat, alpha: CGFloat) -> TTColor
    {
        return NSColor (
            calibratedHue: hue,
            saturation: saturation,
            brightness: brightness,
            alpha: alpha)
    }

    static func make (color: Color) -> NSColor
    {
        let r = CGFloat(color.red) / 65535.0
        let g = CGFloat(color.green) / 65535.0
        let b = CGFloat(color.blue) / 65535.0
        let cg = CGColor(colorSpace: srgbColorSpace, components: [r, g, b, 1.0])!
        return NSColor(cgColor: cg)!
    }

    static func transparent () -> NSColor {
        return NSColor (calibratedWhite: 0, alpha: 0)
    }
}

extension NSBezierPath {
    func addLine(to: CGPoint)
    {
        self.line (to: to)
    }
}

extension NSView {
    func rectsBeingDrawn() -> [CGRect] {
       var rectsPtr: UnsafePointer<CGRect>? = nil
       var count: Int = 0
       self.getRectsBeingDrawn(&rectsPtr, count: &count)

       return Array(UnsafeBufferPointer(start: rectsPtr, count: count))
     }

    public func pending(_ msg: String = "PENDING RECTS") {
        print (msg)
        for x in rectsBeingDrawn() {
            print ("   -> \(x)")
        }
    }
}
extension NSAttributedString {
    func fuzzyHasSelectionBackground (_ ignored: Bool) -> Bool
    {
        return attributeKeys.contains(NSAttributedString.Key.selectionBackgroundColor.rawValue)
    }
}
#endif
