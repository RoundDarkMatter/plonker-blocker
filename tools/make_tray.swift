import AppKit

// Generates src/TrayIcon.pdf — a vector, template menu-bar glyph (derpy
// prohibition face) mirroring src/TrayIcon.svg. PDF is used at runtime because
// NSImage(contentsOf:) decodes standalone SVG files only on macOS 14+, whereas it
// has loaded PDF as a template image since long before macOS 11 — so the custom
// tray icon renders across the whole 11–26 range. Run:  swift tools/make_tray.swift

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "src/TrayIcon.pdf"
let S: CGFloat = 18                       // menu-bar point size (vector — scales freely)
let data = NSMutableData()
var box = CGRect(x: 0, y: 0, width: S, height: S)
let consumer = CGDataConsumer(data: data as CFMutableData)!
guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { fatalError("pdf ctx") }

ctx.beginPDFPage(nil)
// Map the SVG's 24-unit, y-down space into the y-up PDF page.
let k = S / 24.0
ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: k, y: -k)
ctx.setStrokeColor(NSColor.black.cgColor)   // template: the menu bar tints it
ctx.setFillColor(NSColor.black.cgColor)
ctx.setLineWidth(2); ctx.setLineCap(.round); ctx.setLineJoin(.round)

ctx.addEllipse(in: CGRect(x: 2, y: 2, width: 20, height: 20)); ctx.strokePath()   // circle r10 @ (12,12)
ctx.move(to: CGPoint(x: 5, y: 5)); ctx.addLine(to: CGPoint(x: 19, y: 19)); ctx.strokePath()  // slash
ctx.addEllipse(in: CGRect(x: 8, y: 9, width: 2, height: 2)); ctx.fillPath()       // eye @ (9,10)
ctx.addEllipse(in: CGRect(x: 14, y: 8, width: 2, height: 2)); ctx.fillPath()      // eye @ (15,9)
ctx.move(to: CGPoint(x: 9, y: 15))                                                // mouth M9,15 Q12,17 15,14
ctx.addQuadCurve(to: CGPoint(x: 15, y: 14), control: CGPoint(x: 12, y: 17)); ctx.strokePath()
ctx.endPDFPage(); ctx.closePDF()

try! (data as Data).write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
