import AppKit

// Rasterizes src/AppIcon.svg (the color "plonker face + prohibition sign" mark)
// into an .iconset at every macOS icon size, then runs `iconutil` to produce
// src/AppIcon.icns. Run from the repo root:  swift tools/make_icon.swift

let root = FileManager.default.currentDirectoryPath
let svgPath = root + "/src/AppIcon.svg"
let iconsetPath = root + "/build/AppIcon.iconset"
let icnsPath = root + "/src/AppIcon.icns"

guard let svg = NSImage(contentsOfFile: svgPath) else {
    FileHandle.standardError.write(Data("error: can't load \(svgPath)\n".utf8)); exit(1)
}

try? FileManager.default.removeItem(atPath: iconsetPath)
try! FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

func writePNG(pixels: Int, name: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    svg.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
             from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(iconsetPath)/\(name)"))
}

for pt in [16, 32, 128, 256, 512] {
    writePNG(pixels: pt, name: "icon_\(pt)x\(pt).png")
    writePNG(pixels: pt * 2, name: "icon_\(pt)x\(pt)@2x.png")
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconsetPath, "-o", icnsPath]
try! p.run(); p.waitUntilExit()
guard p.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("error: iconutil failed\n".utf8)); exit(1)
}
print("wrote \(icnsPath)")
