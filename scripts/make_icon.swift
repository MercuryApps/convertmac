import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 28
shadow.set()
NSColor.black.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(colors: [
    NSColor(calibratedRed: 1.00, green: 0.42, blue: 0.29, alpha: 1),
    NSColor(calibratedRed: 0.93, green: 0.20, blue: 0.52, alpha: 1),
    NSColor(calibratedRed: 0.45, green: 0.24, blue: 0.95, alpha: 1),
])!.draw(in: shape, angle: -55)

func symbol(_ name: String, _ pt: CGFloat, _ weight: NSFont.Weight, _ alpha: CGFloat, center: NSPoint) {
    let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: weight)
        .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.white.withAlphaComponent(alpha)]))
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
    let s = img.size
    img.draw(in: NSRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height))
}
let c = NSPoint(x: size / 2, y: size / 2)
symbol("arrow.triangle.2.circlepath", 520, .semibold, 0.95, center: c)
symbol("play.fill", 170, .black, 1.0, center: NSPoint(x: c.x + 14, y: c.y))

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
