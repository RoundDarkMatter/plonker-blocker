import AppKit
import UniformTypeIdentifiers

// Generates an original "Ah ah ah!" wagging-finger animation (fallback if the
// user hasn't supplied their own ahahah.gif). No third-party artwork.

let W = 300, H = 300
let cardBG = NSColor(srgbRed: 0.13, green: 0.14, blue: 0.18, alpha: 1)
let frameCount = 14

func frame(_ i: Int) -> CGImage {
    let angle = CGFloat(sin(Double(i) / Double(frameCount) * 2 * .pi) * 20) // wag ±20°
    let img = NSImage(size: NSSize(width: W, height: H))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    cardBG.setFill()
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

    // Wagging finger emoji, rotated about its center.
    let finger = "☝️" as NSString
    let fAttr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 120)]
    let fs = finger.size(withAttributes: fAttr)
    ctx.saveGState()
    ctx.translateBy(x: CGFloat(W) / 2, y: CGFloat(H) / 2 + 6)
    ctx.rotate(by: angle * .pi / 180)
    finger.draw(at: CGPoint(x: -fs.width / 2, y: -fs.height / 2), withAttributes: fAttr)
    ctx.restoreGState()

    func center(_ s: String, _ font: NSFont, _ color: NSColor, _ y: CGFloat) {
        let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let ns = s as NSString
        let sz = ns.size(withAttributes: a)
        ns.draw(at: CGPoint(x: (CGFloat(W) - sz.width) / 2, y: y), withAttributes: a)
    }
    center("Ah ah ah!", .boldSystemFont(ofSize: 34), .white, CGFloat(H) - 66)
    center("You didn't say", .systemFont(ofSize: 15), NSColor(white: 0.7, alpha: 1), 44)
    center("the magic word", .systemFont(ofSize: 15), NSColor(white: 0.7, alpha: 1), 24)

    img.unlockFocus()
    return img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ahahah.gif"
let url = URL(fileURLWithPath: out)
let dest = CGImageDestinationCreateWithURL(
    url as CFURL, UTType.gif.identifier as CFString, frameCount, nil)!
CGImageDestinationSetProperties(dest, [
    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
] as CFDictionary)
for i in 0..<frameCount {
    CGImageDestinationAddImage(dest, frame(i), [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.08],
    ] as CFDictionary)
}
if CGImageDestinationFinalize(dest) { print("wrote \(out)") } else { print("failed") }
