import AppKit

// A quiet, continuous "m" waveform on a teal macOS tile. Render exact pixel
// dimensions so Retina display scaling cannot change the iconset sizes.
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let variants = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func render(size: Int, to url: URL) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32),
        let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { throw CocoaError(.fileWriteUnknown) }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.cgContext.setShouldAntialias(true)
    let d = CGFloat(size)
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: d * x, y: d * y) }
    let tileRect = NSRect(x: d * 0.0625, y: d * 0.0625, width: d * 0.875, height: d * 0.875)
    let tile = NSBezierPath(roundedRect: tileRect, xRadius: d * 0.205, yRadius: d * 0.205)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x03171E, alpha: 0.34)
    shadow.shadowOffset = NSSize(width: 0, height: -d * 0.015)
    shadow.shadowBlurRadius = d * 0.025
    shadow.set()
    color(0x0B2630).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [color(0x10323F), color(0x185668), color(0x26767A)])!
        .draw(in: tile, angle: 65)
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    let halo = NSBezierPath(ovalIn: NSRect(x: -d * 0.12, y: d * 0.24, width: d, height: d))
    NSGradient(colors: [color(0x80D9B6, alpha: 0.26), color(0x80D9B6, alpha: 0)])!
        .draw(in: halo, relativeCenterPosition: NSPoint(x: -0.18, y: 0.15))
    NSGraphicsContext.restoreGraphicsState()

    tile.lineWidth = max(0.5, d * 0.002)
    color(0xC3F8E6, alpha: 0.18).setStroke()
    tile.stroke()

    let mark = NSBezierPath()
    mark.move(to: point(0.255, 0.365))
    mark.curve(to: point(0.375, 0.65), controlPoint1: point(0.255, 0.54),
               controlPoint2: point(0.295, 0.65))
    mark.curve(to: point(0.5, 0.43), controlPoint1: point(0.455, 0.65),
               controlPoint2: point(0.44, 0.43))
    mark.curve(to: point(0.625, 0.65), controlPoint1: point(0.56, 0.43),
               controlPoint2: point(0.545, 0.65))
    mark.curve(to: point(0.745, 0.365), controlPoint1: point(0.705, 0.65),
               controlPoint2: point(0.745, 0.54))
    mark.lineWidth = max(1.5, d * 0.077)
    mark.lineCapStyle = .round
    mark.lineJoinStyle = .round

    NSGraphicsContext.saveGraphicsState()
    let markShadow = NSShadow()
    markShadow.shadowColor = color(0x031E29, alpha: 0.40)
    markShadow.shadowOffset = NSSize(width: 0, height: -d * 0.012)
    markShadow.shadowBlurRadius = d * 0.012
    markShadow.set()
    color(0xC4F7E5).setStroke()
    mark.stroke()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: url)
}

for (name, size) in variants {
    try render(size: size, to: destination.appendingPathComponent(name))
}
