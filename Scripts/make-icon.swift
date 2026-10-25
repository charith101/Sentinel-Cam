// Generates Resources/AppIcon-1024.png, drawn fully in code, shaped to the
// macOS Big Sur squircle per Apple's icon template geometry.
//
// Design: deep navy gradient field (rises out of the status-bar/video context),
// a large front-facing glassy camera lens with metallic bezel, and a red
// "live" recording badge — reads clearly from 16 px up to full size.
//
// Run: swift Scripts/make-icon.swift
import AppKit

let canvas = 1024.0
// Apple's macOS app icon template geometry: 824×824 shape on a 1024 canvas.
let iconRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let radius = 185.4
let lensCenter = CGPoint(x: iconRect.midX, y: iconRect.midY)
let squircle = CGPath(roundedRect: iconRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// MARK: drawing helpers

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1.0) -> CGColor {
  CGColor(
    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
    green: CGFloat((hex >> 8) & 0xFF) / 255.0,
    blue: CGFloat(hex & 0xFF) / 255.0,
    alpha: alpha)
}

let colorSpace = CGColorSpaceCreateDeviceRGB()

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
  CGGradient(
    colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)!
}

/// Fills a path with a linear gradient from `from` to `to`.
func fillLinear(
  _ context: CGContext, _ path: CGPath, from: CGPoint, to: CGPoint,
  _ colors: [CGColor], _ locations: [CGFloat]
) {
  context.saveGState()
  context.addPath(path)
  context.clip()
  context.drawLinearGradient(gradient(colors, locations), start: from, end: to, options: [])
  context.restoreGState()
}

/// Fills a path with a radial gradient; `origin` is the hotspot, `radius` the falloff end.
func fillRadial(
  _ context: CGContext, _ path: CGPath, origin: CGPoint, radius: CGFloat,
  _ colors: [CGColor], _ locations: [CGFloat]
) {
  context.saveGState()
  context.addPath(path)
  context.clip()
  context.drawRadialGradient(
    gradient(colors, locations), startCenter: origin, startRadius: 0,
    endCenter: CGPoint(x: origin.x, y: origin.y), endRadius: radius,
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
  context.restoreGState()
}

/// Stroke an arc with a round cap.
func strokeArc(
  _ context: CGContext, center: CGPoint, radius: CGFloat,
  start: CGFloat, end: CGFloat, width: CGFloat, color: CGColor
) {
  context.saveGState()
  context.setLineCap(.round)
  context.setStrokeColor(color)
  context.setLineWidth(width)
  context.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
  context.strokePath()
  context.restoreGState()
}

func circlePath(center: CGPoint, radius: CGFloat) -> CGPath {
  CGPath(ellipseIn: CGRect(
    x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), transform: nil)
}

// MARK: canvas

let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()
guard let context = NSGraphicsContext.current?.cgContext else {
  fatalError("no graphics context")
}
context.interpolationQuality = .high

// --- Background squircle: deep navy field, lighter above, near-black below. ---
fillLinear(
  context, squircle,
  from: CGPoint(x: iconRect.midX, y: iconRect.maxY),
  to: CGPoint(x: iconRect.midX, y: iconRect.minY),
  [rgb(0x46587C), rgb(0x23304A), rgb(0x101624)], [0.0, 0.55, 1.0])

// A subtle cool glow rising from behind the lens gives the field depth.
fillRadial(
  context, squircle,
  origin: CGPoint(x: lensCenter.x, y: lensCenter.y + 40), radius: 430,
  [rgb(0x7E9FD6, 0.42), rgb(0x7E9FD6, 0.0)], [0.0, 1.0])

// Apple-style top sheen: the upper half of the squircle catches soft light.
let sheenRect = CGRect(
  x: iconRect.minX, y: iconRect.midY, width: iconRect.width, height: iconRect.height / 2)
let sheenClip = CGPath(roundedRect: iconRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
fillLinear(
  context, sheenClip,
  from: CGPoint(x: iconRect.midX, y: iconRect.maxY),
  to: CGPoint(x: iconRect.midX, y: iconRect.midY),
  [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0.0)], [0.0, 1.0])
_ = sheenRect

// Hairline glass edge on the top rim of the squircle.
context.saveGState()
context.addPath(squircle)
context.setStrokeColor(rgb(0xFFFFFF, 0.14))
context.setLineWidth(2)
context.clip(to: CGRect(
  x: iconRect.minX, y: iconRect.midY, width: iconRect.width, height: iconRect.height / 2))
context.strokePath()
context.restoreGState()

// --- The lens ---
// Geometry, from the outside in.
let rMetal = 252.0        // outer metallic bezel
let rMetalInner = 212.0
let rBezel = 212.0        // dark ring between metal and glass
let rGlass = 198.0        // glass dome
let rBarrel = 116.0       // inner barrel ring
let rPupil = 90.0         // eye of the lens

// The glint hotspot sits up and to the left, as on real optics.
let glint = CGPoint(x: lensCenter.x - 68, y: lensCenter.y + 84)

// Metallic bezel: brushed aluminum catching light from the top-left.
fillLinear(
  context, circlePath(center: lensCenter, radius: rMetal),
  from: CGPoint(x: lensCenter.x - rMetal, y: lensCenter.y + rMetal),
  to: CGPoint(x: lensCenter.x + rMetal, y: lensCenter.y - rMetal),
  [rgb(0xF2F5F9), rgb(0xB9C4D1), rgb(0x606D7D), rgb(0x8894A3)],
  [0.0, 0.38, 0.78, 1.0])

// Inner shadow so the metal band reads as thick, with a faint glyph drop shadow.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.3))
context.addPath(circlePath(center: lensCenter, radius: rBezel))
context.setFillColor(rgb(0x141A26))
context.fillPath()
context.restoreGState()

// Glass dome: deep blue-black with an off-center highlight.
let glass = circlePath(center: lensCenter, radius: rGlass)
fillRadial(
  context, glass,
  origin: glint, radius: rGlass * 2.05,
  [rgb(0x9DB4D9), rgb(0x43547A), rgb(0x16203A), rgb(0x070C18)],
  [0.0, 0.28, 0.62, 1.0])

// Soft sheen across the top-left of the glass.
fillRadial(
  context, glass,
  origin: CGPoint(x: lensCenter.x - rGlass * 0.52, y: lensCenter.y + rGlass * 0.55),
  radius: rGlass * 1.4,
  [rgb(0xFFFFFF, 0.30), rgb(0xFFFFFF, 0.0)], [0.0, 1.0])

// Inner barrel shading: the metal throat of the lens.
fillRadial(
  context, circlePath(center: lensCenter, radius: rBarrel),
  origin: glint, radius: rBarrel * 1.5,
  [rgb(0x3A465F), rgb(0x141B29), rgb(0x060A12)], [0.0, 0.5, 1.0])

// Pupil: darkest point just off-center, ring of iris visible at the rim.
fillRadial(
  context, circlePath(center: lensCenter, radius: rPupil),
  origin: lensCenter, radius: rPupil,
  [rgb(0x11151D), rgb(0x1D2431), rgb(0x2C3648)],
  [0.0, 0.72, 1.0])

// Crisp specular arcs, as if the dome reflects a window.
strokeArc(
  context, center: lensCenter, radius: 168,
  start: 118, end: 166, width: 17, color: rgb(0xFFFFFF, 0.30))
strokeArc(
  context, center: lensCenter, radius: 148,
  start: 130, end: 152, width: 9, color: rgb(0xFFFFFF, 0.45))
// Faint secondary reflection low on the glass.
strokeArc(
  context, center: lensCenter, radius: 178,
  start: -62, end: -34, width: 7, color: rgb(0xDDE9FF, 0.12))
// Blue anti-reflective coating glint inside the pupil.
strokeArc(
  context, center: lensCenter, radius: 58,
  start: 152, end: 196, width: 11, color: rgb(0x7FD4FF, 0.38))
// Small hot glint dot near the pupil's edge.
fillRadial(
  context, circlePath(center: CGPoint(x: lensCenter.x + 44, y: lensCenter.y + 52), radius: 30),
  origin: CGPoint(x: lensCenter.x + 44, y: lensCenter.y + 52), radius: 30,
  [rgb(0xFFFFFF, 0.75), rgb(0xFFFFFF, 0.0)], [0.0, 1.0])

// --- Live badge: red recording dot on the bezel, upper right. ---
// Clip to the squircle so the glow never spills past the icon's silhouette.
context.saveGState()
context.addPath(squircle)
context.clip()

let badgeAngle = 42.0 * .pi / 180
let badgeR = rMetal * 0.925
let badgeCenter = CGPoint(
  x: lensCenter.x + badgeR * cos(badgeAngle), y: lensCenter.y + badgeR * sin(badgeAngle))
let badgeRDot = 30.0

// Glow halo.
fillRadial(
  context, circlePath(center: badgeCenter, radius: 70),
  origin: badgeCenter, radius: 70,
  [rgb(0xFF3B4E, 0.5), rgb(0xFF3B4E, 0.0)], [0.0, 1.0])
// Dot body.
fillRadial(
  context, circlePath(center: badgeCenter, radius: badgeRDot),
  origin: CGPoint(x: badgeCenter.x - 8, y: badgeCenter.y + 9), radius: badgeRDot * 1.5,
  [rgb(0xFF9A93), rgb(0xE6303E), rgb(0x9E0F1D)],
  [0.0, 0.55, 1.0])
// Rim light on the dot.
context.addPath(circlePath(center: badgeCenter, radius: badgeRDot - 1.5))
context.setStrokeColor(rgb(0xFFFFFF, 0.5))
context.setLineWidth(3)
context.strokePath()

context.restoreGState()

// Dark glass bottom edge: grounds the circle so it doesn't float.
strokeArc(
  context, center: lensCenter, radius: rMetal - 1,
  start: 208, end: 332, width: 5, color: rgb(0x000000, 0.35))

image.unlockFocus()

let tiff = image.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "Resources/AppIcon-1024.png"))
print("wrote Resources/AppIcon-1024.png")
