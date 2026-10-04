import AppKit

// Reproduce the enabled logo-3.svg mark in each native macOS icon resolution.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for (name, size) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.clear(CGRect(x: 0, y: 0, width: size, height: size))
    cg.translateBy(x: 0, y: CGFloat(size))
    cg.scaleBy(x: CGFloat(size)/100, y: -CGFloat(size)/100)
    cg.setFillColor(NSColor(srgbRed: 241/255, green: 183/255, blue: 76/255, alpha: 1).cgColor)
    cg.setStrokeColor(NSColor(srgbRed: 241/255, green: 183/255, blue: 76/255, alpha: 1).cgColor)
    cg.addPath(CGPath(roundedRect: CGRect(x: 36, y: 12, width: 28, height: 47), cornerWidth: 14, cornerHeight: 14, transform: nil))
    cg.fillPath()
    cg.setLineWidth(8)
    cg.setLineCap(.round)
    cg.move(to: CGPoint(x: 25, y: 46)); cg.addLine(to: CGPoint(x: 25, y: 51))
    cg.addCurve(to: CGPoint(x: 50, y: 76), control1: CGPoint(x: 25, y: 65), control2: CGPoint(x: 36, y: 76))
    cg.addCurve(to: CGPoint(x: 75, y: 51), control1: CGPoint(x: 64, y: 76), control2: CGPoint(x: 75, y: 65))
    cg.addLine(to: CGPoint(x: 75, y: 46)); cg.strokePath()
    cg.move(to: CGPoint(x: 50, y: 77)); cg.addLine(to: CGPoint(x: 50, y: 88)); cg.strokePath()
    cg.move(to: CGPoint(x: 37, y: 89)); cg.addLine(to: CGPoint(x: 63, y: 89)); cg.strokePath()
    cg.setBlendMode(.clear)
    for y in [31,43] {
        cg.addPath(CGPath(roundedRect: CGRect(x: 43, y: y, width: 14, height: 4), cornerWidth: 2, cornerHeight: 2, transform: nil)); cg.fillPath()
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
}
