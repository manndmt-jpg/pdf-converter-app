// Generates Resources/icon_1024.png — run via: swift scripts/make-icon.swift
import AppKit

let size: CGFloat = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS-style rounded tile with margin
let margin: CGFloat = 100
let tile = NSRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()

NSGradient(
    starting: NSColor(calibratedRed: 0.86, green: 0.22, blue: 0.18, alpha: 1),
    ending: NSColor(calibratedRed: 0.55, green: 0.07, blue: 0.10, alpha: 1)
)!.draw(in: tilePath, angle: -90)

NSShadow().set() // reset shadow

// White document with folded corner
let doc = NSRect(x: 322, y: 232, width: 380, height: 540)
let fold: CGFloat = 110
let docPath = NSBezierPath()
docPath.move(to: NSPoint(x: doc.minX, y: doc.minY))
docPath.line(to: NSPoint(x: doc.maxX, y: doc.minY))
docPath.line(to: NSPoint(x: doc.maxX, y: doc.maxY - fold))
docPath.line(to: NSPoint(x: doc.maxX - fold, y: doc.maxY))
docPath.line(to: NSPoint(x: doc.minX, y: doc.maxY))
docPath.close()

let docShadow = NSShadow()
docShadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
docShadow.shadowBlurRadius = 16
docShadow.shadowOffset = NSSize(width: 0, height: -8)
docShadow.set()
NSColor.white.setFill()
docPath.fill()
NSShadow().set()

// Folded corner triangle
let foldPath = NSBezierPath()
foldPath.move(to: NSPoint(x: doc.maxX - fold, y: doc.maxY))
foldPath.line(to: NSPoint(x: doc.maxX - fold, y: doc.maxY - fold))
foldPath.line(to: NSPoint(x: doc.maxX, y: doc.maxY - fold))
foldPath.close()
NSColor(calibratedWhite: 0.82, alpha: 1).setFill()
foldPath.fill()

func drawCentered(_ text: String, y: CGFloat, color: NSColor, fontSize: CGFloat) {
    let font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let str = NSAttributedString(string: text, attributes: attrs)
    let textSize = str.size()
    str.draw(at: NSPoint(x: doc.midX - textSize.width / 2, y: y))
}

// PDF -> MD motif on the document
let red = NSColor(calibratedRed: 0.78, green: 0.12, blue: 0.12, alpha: 1)
let dark = NSColor(calibratedWhite: 0.22, alpha: 1)
drawCentered("PDF", y: 580, color: red, fontSize: 128)

// Down arrow
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: doc.midX - 34, y: 540))
arrow.line(to: NSPoint(x: doc.midX + 34, y: 540))
arrow.line(to: NSPoint(x: doc.midX + 34, y: 470))
arrow.line(to: NSPoint(x: doc.midX + 70, y: 470))
arrow.line(to: NSPoint(x: doc.midX, y: 390))
arrow.line(to: NSPoint(x: doc.midX - 70, y: 470))
arrow.line(to: NSPoint(x: doc.midX - 34, y: 470))
arrow.close()
NSColor(calibratedWhite: 0.55, alpha: 1).setFill()
arrow.fill()

drawCentered("MD", y: 250, color: dark, fontSize: 128)

NSGraphicsContext.current?.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
let out = URL(fileURLWithPath: "Resources/icon_1024.png")
try! FileManager.default.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
try! png.write(to: out)
print("wrote \(out.path)")
