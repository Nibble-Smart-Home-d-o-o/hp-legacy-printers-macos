// Generates a modest-coverage color test page (Letter) as PDF.
// Usage: swift tools/make-color-testpage.swift out.pdf
import CoreGraphics
import CoreText
import Foundation

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "color-test.pdf"
var box = CGRect(x: 0, y: 0, width: 612, height: 792)
guard let ctx = CGContext(URL(fileURLWithPath: out) as CFURL, mediaBox: &box, nil) else { exit(1) }
ctx.beginPDFPage(nil)
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func text(_ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, color: CGColor = .black) {
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    let attr = NSAttributedString(string: s, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color])
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
}

text("HP DeskJet 2130 on macOS - color test", 54, 730, size: 20)
text("hpcups (HPLIP 3.26.6) · \(ProcessInfo.processInfo.operatingSystemVersionString)", 54, 708, size: 10, color: CGColor(gray: 0.35, alpha: 1))

// Primary / secondary patches
let patches: [(String, [CGFloat])] = [
    ("C", [0, 1, 1]), ("M", [1, 0, 1]), ("Y", [1, 1, 0]),
    ("R", [1, 0, 0]), ("G", [0, 0.7, 0]), ("B", [0, 0, 1]), ("K", [0, 0, 0])]
for (i, p) in patches.enumerated() {
    let r = CGRect(x: 54 + CGFloat(i) * 72, y: 600, width: 60, height: 60)
    ctx.setFillColor(CGColor(colorSpace: srgb, components: p.1 + [1])!)
    ctx.fill(r)
    text(p.0, r.midX - 4, 585, size: 10)
}

// Hue gradient strip and gray ramp
let hues = (0...12).map { i -> CGColor in
    let h = CGFloat(i) / 12
    let c = NSColorLike.hsv(h)
    return CGColor(colorSpace: srgb, components: [c.0, c.1, c.2, 1])!
}
let grad = CGGradient(colorsSpace: srgb, colors: hues as CFArray, locations: nil)!
ctx.saveGState(); ctx.clip(to: CGRect(x: 54, y: 520, width: 504, height: 36))
ctx.drawLinearGradient(grad, start: CGPoint(x: 54, y: 0), end: CGPoint(x: 558, y: 0), options: [])
ctx.restoreGState()
let gray = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 0, alpha: 1)] as CFArray, locations: nil)!
ctx.saveGState(); ctx.clip(to: CGRect(x: 54, y: 470, width: 504, height: 24))
ctx.drawLinearGradient(gray, start: CGPoint(x: 54, y: 0), end: CGPoint(x: 558, y: 0), options: [])
ctx.restoreGState()
ctx.setStrokeColor(CGColor(gray: 0.6, alpha: 1)); ctx.setLineWidth(0.5)
ctx.stroke(CGRect(x: 54, y: 470, width: 504, height: 24))

// Concentric color circles
for (i, p) in patches.prefix(6).enumerated() {
    ctx.setStrokeColor(CGColor(colorSpace: srgb, components: p.1 + [1])!)
    ctx.setLineWidth(4)
    let r = CGFloat(110 - i * 16)
    ctx.strokeEllipse(in: CGRect(x: 306 - r, y: 300 - r, width: 2 * r, height: 2 * r))
}
text("Printed \(Date())", 54, 120, size: 10, color: CGColor(gray: 0.35, alpha: 1))
ctx.endPDFPage(); ctx.closePDF()

enum NSColorLike {
    static func hsv(_ h: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let i = Int(h * 6) % 6, f = h * 6 - floor(h * 6)
        switch i {
        case 0: return (1, f, 0); case 1: return (1 - f, 1, 0); case 2: return (0, 1, f)
        case 3: return (0, 1 - f, 1); case 4: return (f, 0, 1); default: return (1, 0, 1 - f)
        }
    }
}
