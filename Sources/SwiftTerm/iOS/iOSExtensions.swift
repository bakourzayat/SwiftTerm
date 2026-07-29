//
//  File.swift
//  
//
//  Created by Miguel de Icaza on 6/29/21.
//
#if os(iOS) || os(visionOS)
import Foundation
import UIKit

extension UIColor {
    func getTerminalColor () -> Color {
        var red: CGFloat = 0.0, green: CGFloat = 0.0, blue: CGFloat = 0.0, alpha: CGFloat = 1.0
        self.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        
        func clamp (_ v: CGFloat) -> CGFloat {
            return min (max (v, 0.0), 1.0)
        }
        return Color(red: UInt16 (clamp (red)*65535), green: UInt16(clamp (green)*65535), blue: UInt16(clamp (blue)*65535))
    }

    func inverseColor() -> UIColor {
        var red: CGFloat = 0.0, green: CGFloat = 0.0, blue: CGFloat = 0.0, alpha: CGFloat = 1.0
        self.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return UIColor (red: 1.0 - red, green: 1.0 - green, blue: 1.0 - blue, alpha: alpha)
    }

    /// Returns a dimmed version of the color (SGR 2 faint/dim attribute) by
    /// blending 50 % toward `background`. The result is fully opaque so that
    /// adjacent box-drawing characters tile without visible seams.
    func dimmedColor (towards background: UIColor) -> UIColor {
        var fRed: CGFloat = 0.0, fGreen: CGFloat = 0.0, fBlue: CGFloat = 0.0, fAlpha: CGFloat = 1.0
        self.getRed(&fRed, green: &fGreen, blue: &fBlue, alpha: &fAlpha)
        var bRed: CGFloat = 0.0, bGreen: CGFloat = 0.0, bBlue: CGFloat = 0.0, bAlpha: CGFloat = 1.0
        background.getRed(&bRed, green: &bGreen, blue: &bBlue, alpha: &bAlpha)
        return UIColor (red: (fRed + bRed) * 0.5,
                        green: (fGreen + bGreen) * 0.5,
                        blue: (fBlue + bBlue) * 0.5,
                        alpha: fAlpha)
    }


    /// KILTER — guarantee a minimum perceived-luminance distance from
    /// `background`. See `KilterContrast` for why this exists.
    ///
    /// Walks the colour toward white or black — whichever side the background
    /// leaves room on — until it clears the floor. A dark panel therefore
    /// gets LIGHTER text and a light page gets DARKER text, which is what a
    /// reader expects and what a program that guessed wrong failed to do.
    /// Returns self untouched when the pair is already far enough apart, so
    /// a palette that was designed properly is never second-guessed.
    func kilterContrasted (against background: UIColor, minimum: CGFloat) -> UIColor {
        guard minimum > 0 else { return self }
        var fR: CGFloat = 0, fG: CGFloat = 0, fB: CGFloat = 0, fA: CGFloat = 1
        var bR: CGFloat = 0, bG: CGFloat = 0, bB: CGFloat = 0, bA: CGFloat = 1
        getRed(&fR, green: &fG, blue: &fB, alpha: &fA)
        background.getRed(&bR, green: &bG, blue: &bB, alpha: &bA)
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
        return UIColor (red: mix (fR), green: mix (fG), blue: mix (fB), alpha: fA)
    }

    static func make (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) -> TTColor
    {
        
        return UIColor(red: red,
                       green: green,
                       blue: blue,
                       alpha: 1.0)
    }
  
    static func make (hue: CGFloat, saturation: CGFloat, brightness: CGFloat, alpha: CGFloat) -> TTColor
    {
        return UIColor(hue: hue,
                       saturation: saturation,
                       brightness: brightness,
                       alpha: alpha)
    }
    
    static func make (color: Color) -> UIColor
    {
        UIColor (red: CGFloat (color.red) / 65535.0,
                 green: CGFloat (color.green) / 65535.0,
                 blue: CGFloat (color.blue) / 65535.0,
                 alpha: 1.0)
    }
    
    static func transparent () -> UIColor {
        return UIColor.clear
    }
}

extension UIImage {
    public convenience init (cgImage: CGImage, size: CGSize) {
        self.init (cgImage: cgImage, scale: -1, orientation: .up)
        //self.init (cgImage: cgImage)
    }
}

extension NSAttributedString {
    func fuzzyHasSelectionBackground (_ ret: Bool) -> Bool
    {
        return ret
    }
}
#endif

