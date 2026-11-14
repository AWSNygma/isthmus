// Renders the Isthmus app icon: two landmasses joined by a narrow
// bridge of land across water. Usage: swift scripts/make-icon.swift out.iconset
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 body with ~185 corner radius.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.225
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    // Water: deep blue → teal.
    let water = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(red: 0.05, green: 0.18, blue: 0.42, alpha: 1).cgColor,
        NSColor(red: 0.02, green: 0.50, blue: 0.62, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(water, start: CGPoint(x: body.minX, y: body.minY), end: CGPoint(x: body.maxX, y: body.maxY), options: [])

    // Wave lines.
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
    ctx.setLineWidth(s * 0.012)
    ctx.setLineCap(.round)
    for i in 0..<7 {
        let y = body.minY + body.height * (0.12 + CGFloat(i) * 0.13)
        let w = CGMutablePath()
        w.move(to: CGPoint(x: body.minX, y: y))
        var x = body.minX
        while x < body.maxX {
            w.addQuadCurve(to: CGPoint(x: x + s * 0.06, y: y), control: CGPoint(x: x + s * 0.03, y: y + s * 0.018))
            x += s * 0.06
        }
        ctx.addPath(w); ctx.strokePath()
    }

    // Land: two masses and the isthmus between them.
    let land = CGMutablePath()
    let c = CGPoint(x: body.midX, y: body.midY)
    let u = body.width
    land.move(to: CGPoint(x: body.minX - 10, y: body.maxY + 10))
    land.addLine(to: CGPoint(x: body.minX - 10, y: c.y + u * 0.05))
    land.addCurve(to: CGPoint(x: c.x - u * 0.06, y: c.y + u * 0.10),
                  control1: CGPoint(x: body.minX + u * 0.15, y: c.y - u * 0.02), control2: CGPoint(x: c.x - u * 0.22, y: c.y + u * 0.16))
    land.addCurve(to: CGPoint(x: c.x + u * 0.06, y: c.y - u * 0.10),
                  control1: CGPoint(x: c.x + u * 0.01, y: c.y + u * 0.06), control2: CGPoint(x: c.x - u * 0.01, y: c.y - u * 0.06))
    land.addCurve(to: CGPoint(x: body.maxX + 10, y: c.y - u * 0.05),
                  control1: CGPoint(x: c.x + u * 0.22, y: c.y - u * 0.16), control2: CGPoint(x: body.maxX - u * 0.15, y: c.y + u * 0.02))
    land.addLine(to: CGPoint(x: body.maxX + 10, y: body.minY - 10))
    land.addLine(to: CGPoint(x: c.x + u * 0.12, y: body.minY - 10))
    land.addCurve(to: CGPoint(x: c.x + u * 0.02, y: c.y - u * 0.13),
                  control1: CGPoint(x: c.x + u * 0.30, y: c.y - u * 0.30), control2: CGPoint(x: c.x + u * 0.12, y: c.y - u * 0.18))
    land.addCurve(to: CGPoint(x: c.x - u * 0.02, y: c.y + u * 0.13),
                  control1: CGPoint(x: c.x - u * 0.04, y: c.y - u * 0.08), control2: CGPoint(x: c.x + u * 0.04, y: c.y + u * 0.08))
    land.addCurve(to: CGPoint(x: c.x - u * 0.12, y: body.maxY + 10),
                  control1: CGPoint(x: c.x - u * 0.12, y: c.y + u * 0.18), control2: CGPoint(x: c.x - u * 0.30, y: c.y + u * 0.30))
    land.closeSubpath()

    // Shore glow, then land fill.
    ctx.saveGState()
    ctx.addPath(land)
    ctx.setStrokeColor(NSColor(red: 0.85, green: 0.95, blue: 0.90, alpha: 0.55).cgColor)
    ctx.setLineWidth(s * 0.035)
    ctx.strokePath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(land); ctx.clip()
    let green = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(red: 0.98, green: 0.80, blue: 0.40, alpha: 1).cgColor,
        NSColor(red: 0.36, green: 0.78, blue: 0.45, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(green, start: CGPoint(x: body.minX, y: body.minY), end: CGPoint(x: body.maxX, y: body.maxY), options: [])
    ctx.restoreGState()

    // Top sheen.
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor.white.withAlphaComponent(0.18).cgColor, NSColor.white.withAlphaComponent(0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: c.x, y: body.maxY), end: CGPoint(x: c.x, y: c.y), options: [])
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: outDir.appendingPathComponent("icon_\(name).png"))
}
print("wrote \(outDir.path)")
