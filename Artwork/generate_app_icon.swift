import AppKit
import Foundation

private let canvasSize = 1024
private let canvas = NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize)

private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

private func point(center: NSPoint, radius: CGFloat, degrees: CGFloat) -> NSPoint {
    let radians = degrees * .pi / 180
    return NSPoint(
        x: center.x + cos(radians) * radius,
        y: center.y + sin(radians) * radius
    )
}

private func strokeArc(
    center: NSPoint,
    radius: CGFloat,
    start: CGFloat,
    end: CGFloat,
    width: CGFloat,
    strokeColor: NSColor
) {
    let path = NSBezierPath()
    path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
    path.lineWidth = width
    path.lineCapStyle = .round
    strokeColor.setStroke()
    path.stroke()
}

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: canvasSize,
    pixelsHigh: canvasSize,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Unable to create bitmap context")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.shouldAntialias = true
context.imageInterpolation = .high
NSColor.clear.setFill()
canvas.fill()

let iconRect = NSRect(x: 64, y: 64, width: 896, height: 896)
let iconPath = NSBezierPath(roundedRect: iconRect, xRadius: 210, yRadius: 210)

NSGraphicsContext.saveGraphicsState()
let outerShadow = NSShadow()
outerShadow.shadowColor = color(0, 0, 0, 0.34)
outerShadow.shadowBlurRadius = 34
outerShadow.shadowOffset = NSSize(width: 0, height: -18)
outerShadow.set()
color(16, 22, 28).setFill()
iconPath.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(
    starting: color(41, 51, 60),
    ending: color(12, 17, 22)
)!.draw(in: iconPath, angle: -90)

let insetPath = NSBezierPath(roundedRect: iconRect.insetBy(dx: 19, dy: 19), xRadius: 194, yRadius: 194)
insetPath.lineWidth = 3
color(255, 255, 255, 0.13).setStroke()
insetPath.stroke()

let center = NSPoint(x: 512, y: 515)
strokeArc(
    center: center,
    radius: 288,
    start: 205,
    end: -25,
    width: 34,
    strokeColor: color(255, 255, 255, 0.12)
)
strokeArc(
    center: center,
    radius: 288,
    start: 205,
    end: 126,
    width: 34,
    strokeColor: color(55, 205, 224)
)
strokeArc(
    center: center,
    radius: 288,
    start: 126,
    end: 42,
    width: 34,
    strokeColor: color(255, 255, 255, 0.9)
)
strokeArc(
    center: center,
    radius: 288,
    start: 42,
    end: -25,
    width: 34,
    strokeColor: color(255, 153, 45)
)

for index in 0...10 {
    let degrees = 205 - CGFloat(index) * 23
    let innerRadius: CGFloat = index == 5 ? 229 : 238
    let tick = NSBezierPath()
    tick.move(to: point(center: center, radius: innerRadius, degrees: degrees))
    tick.line(to: point(center: center, radius: 257, degrees: degrees))
    tick.lineWidth = index == 5 ? 13 : 9
    tick.lineCapStyle = .round
    color(255, 255, 255, index == 5 ? 0.95 : 0.58).setStroke()
    tick.stroke()
}

let needleAngle: CGFloat = 55
let needle = NSBezierPath()
needle.move(to: center)
needle.line(to: point(center: center, radius: 218, degrees: needleAngle))
needle.lineWidth = 20
needle.lineCapStyle = .round
color(255, 255, 255, 0.95).setStroke()
needle.stroke()

let hubShadow = NSShadow()
hubShadow.shadowColor = color(0, 0, 0, 0.35)
hubShadow.shadowBlurRadius = 13
hubShadow.shadowOffset = NSSize(width: 0, height: -5)
hubShadow.set()
let hub = NSBezierPath(ovalIn: NSRect(x: 472, y: 475, width: 80, height: 80))
color(55, 205, 224).setFill()
hub.fill()
NSShadow().set()
let hubCenter = NSBezierPath(ovalIn: NSRect(x: 491, y: 494, width: 42, height: 42))
color(247, 250, 252).setFill()
hubCenter.fill()

let bolt = NSBezierPath()
bolt.move(to: NSPoint(x: 548, y: 762))
bolt.line(to: NSPoint(x: 392, y: 485))
bolt.line(to: NSPoint(x: 500, y: 485))
bolt.line(to: NSPoint(x: 466, y: 276))
bolt.line(to: NSPoint(x: 640, y: 570))
bolt.line(to: NSPoint(x: 530, y: 570))
bolt.close()

NSGraphicsContext.saveGraphicsState()
let boltShadow = NSShadow()
boltShadow.shadowColor = color(255, 116, 22, 0.34)
boltShadow.shadowBlurRadius = 24
boltShadow.shadowOffset = .zero
boltShadow.set()
NSGradient(
    starting: color(255, 194, 67),
    ending: color(255, 116, 30)
)!.draw(in: bolt, angle: -90)
NSGraphicsContext.restoreGraphicsState()

let highlight = NSBezierPath()
highlight.move(to: NSPoint(x: 536, y: 710))
highlight.line(to: NSPoint(x: 432, y: 515))
highlight.lineWidth = 10
highlight.lineCapStyle = .round
color(255, 242, 205, 0.5).setStroke()
highlight.stroke()

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to encode PNG")
}

let outputPath = ProcessInfo.processInfo.environment["STATS_APP_ICON_OUTPUT"] ?? "Artwork/AppIcon-1024.png"
let outputURL = URL(fileURLWithPath: outputPath)
try png.write(to: outputURL)
print(outputURL.path)
