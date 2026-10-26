import Foundation
import CoreGraphics // CGRect.

// Tells the front of a stop sign (red) from the back (gray or white). The model has one "stop sign" class and
// fires on both. Pure pixel math with no camera or Vision, so it also runs in the Mac replay tool.
enum SignColor {
    static let minBoxPixels = 25.0 // Boxes shorter than this have too few pixels to judge; they are left alone (nil).
    static let minRedTint = 0.10 // Below this share of red-tinted pixels, it is not a sign front.
    static let edgeMargin = 0.2 // Ignore this much of each side of the box: the octagon doesn't fill it, and the rim is background.
    static let centerSkip = 0.5 // Ignore the middle half of the box's width too. On the back of a sign the (orange-brown) post
    // runs down the middle and looks red-tinted; on a front the middle is mostly white lettering anyway.
    static let redLead = 8 // A pixel is red-tinted when red beats both green and blue by more than this (0...255).
    // Shadowed and dusk signs are dark but still have red above green and blue; a "bright red" test rejected them.
    static let greenOverBlue = 0.25 // ...and green may not sit above blue by more than this * (red - lower of the two).
    // Orange and yellow (warning signs, pumpkins) have green far above blue, and sunlit white or wood is warm the same way,
    // so without this they all read as red. Blue ABOVE green is allowed on purpose: the camera renders real stop-sign red
    // as pinkish (typically R 150, G 80, B 100). Settings come from a search over 107 hand-labeled sightings (4 recordings).

    // The pixel rectangle inside a box that gets judged (the box minus its edge margin), or nil if the box is too small.
    // `box` is in Vision coordinates (0...1, origin bottom-left).
    static func region(width: Int, height: Int, box: CGRect) -> (x0: Int, x1: Int, y0: Int, y1: Int)? {
        let top = (1 - box.maxY) * Double(height), bottom = (1 - box.minY) * Double(height) // Image rows grow downward.
        let left = box.minX * Double(width), right = box.maxX * Double(width)
        guard bottom - top >= minBoxPixels else { return nil }
        let margin = Int(edgeMargin * min(bottom - top, right - left))
        let y0 = max(Int(top) + margin, 0), y1 = min(Int(bottom) - margin, height)
        let x0 = max(Int(left) + margin, 0), x1 = min(Int(right) - margin, width)
        guard y1 > y0, x1 > x0 else { return nil }
        return (x0, x1, y0, y1)
    }

    // Share (0...1) of red-tinted pixels in the middle of the box, or nil if the box is too small to judge.
    // `box` is in Vision coordinates (0...1, origin bottom-left); the pixels are BGRA, the camera's format.
    static func redTintFraction(base: UnsafePointer<UInt8>, width: Int, height: Int, rowBytes: Int, box: CGRect) -> Double? {
        guard let (x0, x1, y0, y1) = region(width: width, height: height, box: box) else { return nil }
        let step = max(1, min(y1 - y0, x1 - x0) / 64) // Plenty of samples; keeps big boxes cheap.
        let skipFrom = Double(x0) + Double(x1 - x0) * (1 - centerSkip) / 2, skipTo = Double(x0) + Double(x1 - x0) * (1 + centerSkip) / 2
        var red = 0, total = 0
        var y = y0
        while y < y1 {
            var x = x0
            while x < x1 {
                if Double(x) >= skipFrom && Double(x) < skipTo { x += step; continue }
                let p = base + y * rowBytes + x * 4 // B, G, R, A
                let blue = Int(p[0]), green = Int(p[1]), r = Int(p[2])
                let span = r - min(green, blue) // How far red sticks out above the weaker of the other two.
                if r > green + redLead && r > blue + redLead && Double(green - blue) <= greenOverBlue * Double(span) { red += 1 }
                total += 1
                x += step
            }
            y += step
        }
        return total > 0 ? Double(red) / Double(total) : nil
    }

    // Same, for an in-memory image (tests and the replay tool).
    static func redTintFraction(bgra: [UInt8], width: Int, height: Int, rowBytes: Int, box: CGRect) -> Double? {
        bgra.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.flatMap { redTintFraction(base: $0, width: width, height: height, rowBytes: rowBytes, box: box) }
        }
    }

    // Unjudged boxes (nil) are kept: better a possible back than a missed sign.
    static func looksLikeFront(tint: Double?) -> Bool { tint.map { $0 >= minRedTint } ?? true }
}
