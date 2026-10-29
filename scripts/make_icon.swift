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
    NSColor(srgbRed: 0.165, green: 0.180, blue: 0.259, alpha: 1),
    NSColor(srgbRed: 0.078, green: 0.086, blue: 0.122, alpha: 1),
])!.draw(in: shape, angle: -90)

NSColor.white.withAlphaComponent(0.08).setStroke()
let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 184.5, yRadius: 184.5)
edge.lineWidth = 1
edge.stroke()

let play = NSBezierPath()
play.move(to: NSPoint(x: 270, y: 352))
play.line(to: NSPoint(x: 270, y: 672))
play.line(to: NSPoint(x: 500, y: 512))
play.close()
play.lineWidth = 40
play.lineJoinStyle = .round
let periwinkle = NSColor(srgbRed: 0.667, green: 0.702, blue: 1.0, alpha: 1)
periwinkle.setFill()
periwinkle.setStroke()
play.fill()
play.stroke()

NSColor(srgbRed: 0.965, green: 0.765, blue: 0.545, alpha: 1).setFill()
for (x, h) in [(554.0, 220.0), (638.0, 380.0), (722.0, 260.0)] {
    NSBezierPath(roundedRect: NSRect(x: x, y: 512 - h / 2, width: 48, height: h), xRadius: 24, yRadius: 24).fill()
}

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
