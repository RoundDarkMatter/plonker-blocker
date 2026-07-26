// Plonker Blocker — Copyright 2026 RoundDarkMatter
// SPDX-License-Identifier: Apache-2.0

import AppKit

// Renders docs/banner.png — the README hero image: the app icon on a dark indigo
// backdrop with the wordmark, tagline, and a small spec line. Run from the repo
// root:  swift tools/make_banner.swift

let W: CGFloat = 1280, H: CGFloat = 400, scale: CGFloat = 2   // 2x for crispness
let out = "docs/banner.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)   // logical 1280×400 drawn into a 2x bitmap

NSGraphicsContext.saveGraphicsState()
let gctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = gctx
gctx.imageInterpolation = .high
let cg = gctx.cgContext

// Background: deep indigo vertical gradient.
let top = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.18, alpha: 1)
let mid = NSColor(srgbRed: 0.07, green: 0.07, blue: 0.12, alpha: 1)
let bot = NSColor(srgbRed: 0.03, green: 0.03, blue: 0.06, alpha: 1)
NSGradient(colors: [top, mid, bot], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

// Violet glow behind the icon (fades fully to transparent — no seam).
let glow = NSColor(srgbRed: 0.42, green: 0.36, blue: 0.85, alpha: 0.32)
if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [glow.cgColor, glow.withAlphaComponent(0).cgColor] as CFArray,
                      locations: [0, 1]) {
    let c = CGPoint(x: 235, y: H * 0.56)
    cg.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: 360, options: [])
}

// App icon (left).
let iconSize: CGFloat = 300
if let icon = NSImage(contentsOfFile: "src/AppIcon.svg") {
    icon.draw(in: NSRect(x: 78, y: (H - iconSize) / 2, width: iconSize, height: iconSize),
              from: .zero, operation: .sourceOver, fraction: 1)
}

// Text (right). Non-flipped context: rect.y from bottom, text fills from rect top.
func text(_ s: String, _ font: NSFont, _ color: NSColor, x: CGFloat, top: CGFloat, w: CGFloat, h: CGFloat,
          lineHeight: CGFloat? = nil) {
    let p = NSMutableParagraphStyle(); p.alignment = .left
    if let lh = lineHeight { p.minimumLineHeight = lh; p.maximumLineHeight = lh }
    let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: p]
    (s as NSString).draw(in: NSRect(x: x, y: H - top - h, width: w, height: h), withAttributes: a)
}
let tx: CGFloat = 430
text("Plonker Blocker", .systemFont(ofSize: 76, weight: .bold), .white, x: tx, top: 104, w: 820, h: 92)
text("Lock any macOS app behind a passcode,\nTouch ID, or an administrator password.",
     .systemFont(ofSize: 27, weight: .regular), NSColor(white: 0.74, alpha: 1),
     x: tx + 2, top: 206, w: 800, h: 82, lineHeight: 37)

text("macOS 11 – 26   ·   universal (arm64 + x86_64)   ·   Apache 2.0",
     .systemFont(ofSize: 19, weight: .medium), NSColor(white: 0.5, alpha: 1), x: tx + 2, top: 306, w: 820, h: 28)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)  (\(Int(W * scale))×\(Int(H * scale)) px)")
