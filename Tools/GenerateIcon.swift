import AppKit
import CoreGraphics

// 择影 app icon
//
// The icon is deliberately made from a small number of clear shapes so it stays
// legible at the size of an iPhone home screen icon. The system supplies the
// final rounded mask; the artwork itself fills the 1024 × 1024 canvas.
let side = 1024
let canvas = CGFloat(side)

guard CommandLine.arguments.count > 1 else {
    fputs("Usage: GenerateIcon.swift <output.png>\n", stderr)
    exit(1)
}

let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: side,
    pixelsHigh: side,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Could not create drawing context\n", stderr)
    exit(1)
}
NSGraphicsContext.current = graphicsContext
graphicsContext.imageInterpolation = .high
graphicsContext.shouldAntialias = true

let context = graphicsContext.cgContext

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
}

func roundedPath(in rect: CGRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func drawGradient(in rect: CGRect, colors: [NSColor], angle: CGFloat) {
    NSGradient(colors: colors)?.draw(in: rect, angle: angle)
}

func drawSoftGlow(center: CGPoint, radius: CGFloat, color: NSColor) {
    context.saveGState()
    let colors = [color.withAlphaComponent(0.24).cgColor, color.withAlphaComponent(0).cgColor] as CFArray
    let locations: [CGFloat] = [0, 1]
    guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations) else {
        context.restoreGState()
        return
    }
    context.drawRadialGradient(
        gradient,
        startCenter: center,
        startRadius: 0,
        endCenter: center,
        endRadius: radius,
        options: [.drawsAfterEndLocation]
    )
    context.restoreGState()
}

func drawBackPhotoCard() {
    let rect = CGRect(x: 151, y: 190, width: 595, height: 645)
    context.saveGState()
    context.translateBy(x: rect.midX, y: rect.midY)
    context.rotate(by: -0.14)
    let localRect = CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height)
    let path = roundedPath(in: localRect, radius: 78)

    context.setShadow(offset: CGSize(width: 0, height: -24), blur: 40, color: NSColor.black.withAlphaComponent(0.32).cgColor)
    path.addClip()
    drawGradient(
        in: localRect,
        colors: [color(0.73, 0.80, 0.91), color(0.47, 0.53, 0.72)],
        angle: -38
    )
    context.setShadow(offset: .zero, blur: 0, color: nil)

    path.lineWidth = 3
    color(0.86, 0.90, 0.98, 0.62).setStroke()
    path.stroke()
    context.restoreGState()
}

func drawPhotoScene(in rect: CGRect, radius: CGFloat) {
    let path = roundedPath(in: rect, radius: radius)
    context.saveGState()
    path.addClip()

    drawGradient(
        in: rect,
        colors: [color(0.48, 0.73, 0.78), color(0.95, 0.63, 0.48)],
        angle: -28
    )

    // A small sun makes the object read as a photograph, while the two simple
    // landscape layers keep the mark calm when reduced to home-screen size.
    let sunCenter = CGPoint(x: rect.minX + rect.width * 0.73, y: rect.minY + rect.height * 0.73)
    let sunRadius = rect.width * 0.105
    color(1.0, 0.82, 0.53, 0.95).setFill()
    NSBezierPath(ovalIn: CGRect(x: sunCenter.x - sunRadius, y: sunCenter.y - sunRadius, width: sunRadius * 2, height: sunRadius * 2)).fill()

    let farMountain = NSBezierPath()
    farMountain.move(to: CGPoint(x: rect.minX - 24, y: rect.minY + rect.height * 0.16))
    farMountain.line(to: CGPoint(x: rect.minX + rect.width * 0.31, y: rect.minY + rect.height * 0.53))
    farMountain.line(to: CGPoint(x: rect.minX + rect.width * 0.51, y: rect.minY + rect.height * 0.36))
    farMountain.line(to: CGPoint(x: rect.minX + rect.width * 0.71, y: rect.minY + rect.height * 0.57))
    farMountain.line(to: CGPoint(x: rect.maxX + 24, y: rect.minY + rect.height * 0.25))
    farMountain.line(to: CGPoint(x: rect.maxX + 24, y: rect.minY - 24))
    farMountain.line(to: CGPoint(x: rect.minX - 24, y: rect.minY - 24))
    farMountain.close()
    color(0.39, 0.57, 0.65, 0.72).setFill()
    farMountain.fill()

    let nearMountain = NSBezierPath()
    nearMountain.move(to: CGPoint(x: rect.minX - 24, y: rect.minY + rect.height * 0.02))
    nearMountain.line(to: CGPoint(x: rect.minX + rect.width * 0.27, y: rect.minY + rect.height * 0.43))
    nearMountain.line(to: CGPoint(x: rect.minX + rect.width * 0.43, y: rect.minY + rect.height * 0.28))
    nearMountain.line(to: CGPoint(x: rect.minX + rect.width * 0.62, y: rect.minY + rect.height * 0.48))
    nearMountain.line(to: CGPoint(x: rect.maxX + 24, y: rect.minY + rect.height * 0.14))
    nearMountain.line(to: CGPoint(x: rect.maxX + 24, y: rect.minY - 24))
    nearMountain.line(to: CGPoint(x: rect.minX - 24, y: rect.minY - 24))
    nearMountain.close()
    color(0.13, 0.20, 0.32, 0.87).setFill()
    nearMountain.fill()

    // A translucent lower edge gives the photo a quiet glass-like depth.
    let lowerShade = NSBezierPath(rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.14))
    color(0.06, 0.10, 0.18, 0.20).setFill()
    lowerShade.fill()
    context.restoreGState()
}

func drawFrontPhotoCard() {
    let outer = CGRect(x: 213, y: 144, width: 603, height: 692)
    let inner = CGRect(x: outer.minX + 55, y: outer.minY + 118, width: outer.width - 110, height: outer.height - 188)

    context.saveGState()
    context.translateBy(x: outer.midX, y: outer.midY)
    context.rotate(by: 0.055)
    let localOuter = CGRect(x: -outer.width / 2, y: -outer.height / 2, width: outer.width, height: outer.height)
    let localInner = CGRect(x: -inner.width / 2, y: -inner.height / 2 - 4, width: inner.width, height: inner.height)
    let outerPath = roundedPath(in: localOuter, radius: 82)

    context.setShadow(offset: CGSize(width: 0, height: -30), blur: 48, color: NSColor.black.withAlphaComponent(0.40).cgColor)
    color(0.965, 0.955, 0.93).setFill()
    outerPath.fill()
    context.setShadow(offset: .zero, blur: 0, color: nil)

    // The image is clipped to the front card, leaving a generous light frame.
    drawPhotoScene(in: localInner, radius: 52)
    let innerBorder = roundedPath(in: localInner, radius: 52)
    color(1, 1, 1, 0.46).setStroke()
    innerBorder.lineWidth = 3
    innerBorder.stroke()

    // A tiny glassy caption line keeps the lower edge intentionally quiet.
    let captionY = localOuter.minY + 52
    let caption = NSBezierPath(roundedRect: CGRect(x: localOuter.minX + 55, y: captionY, width: 142, height: 13), xRadius: 6.5, yRadius: 6.5)
    color(0.22, 0.28, 0.37, 0.20).setFill()
    caption.fill()

    outerPath.lineWidth = 3
    color(1, 1, 1, 0.68).setStroke()
    outerPath.stroke()
    context.restoreGState()
}

func drawKeepHeart() {
    let center = CGPoint(x: 760, y: 744)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 22, color: NSColor.black.withAlphaComponent(0.38).cgColor)

    // Match the filled cyan Keep heart used in the review controls.
    let heart = NSBezierPath()
    heart.move(to: CGPoint(x: center.x, y: center.y - 66))
    heart.curve(to: CGPoint(x: center.x - 80, y: center.y + 42),
                controlPoint1: CGPoint(x: center.x - 22, y: center.y - 46),
                controlPoint2: CGPoint(x: center.x - 80, y: center.y - 6))
    heart.curve(to: CGPoint(x: center.x, y: center.y + 54),
                controlPoint1: CGPoint(x: center.x - 80, y: center.y + 90),
                controlPoint2: CGPoint(x: center.x - 24, y: center.y + 94))
    heart.curve(to: CGPoint(x: center.x + 80, y: center.y + 42),
                controlPoint1: CGPoint(x: center.x + 24, y: center.y + 94),
                controlPoint2: CGPoint(x: center.x + 80, y: center.y + 90))
    heart.curve(to: CGPoint(x: center.x, y: center.y - 66),
                controlPoint1: CGPoint(x: center.x + 80, y: center.y - 6),
                controlPoint2: CGPoint(x: center.x + 22, y: center.y - 46))
    heart.close()
    color(0.03, 0.66, 0.98).setFill()
    heart.fill()
    context.restoreGState()
}

// Deep blue and plum let the light photo stack separate from the background,
// while the cyan Keep heart provides the one memorable color cue.
drawGradient(
    in: CGRect(x: 0, y: 0, width: canvas, height: canvas),
    colors: [color(0.035, 0.075, 0.14), color(0.105, 0.055, 0.16)],
    angle: -38
)
drawSoftGlow(center: CGPoint(x: 782, y: 772), radius: 520, color: color(0.08, 0.62, 0.95))
drawSoftGlow(center: CGPoint(x: 242, y: 248), radius: 430, color: color(0.12, 0.44, 0.78))

drawBackPhotoCard()
drawFrontPhotoCard()
drawKeepHeart()

NSGraphicsContext.restoreGraphicsState()

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Could not encode PNG\n", stderr)
    exit(1)
}
try png.write(to: destination)
