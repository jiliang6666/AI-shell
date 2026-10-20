import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
let output = arguments.first ?? "Resources/AppIcon.png"
let icnsOutput = arguments.dropFirst().first
let size = 1024
let canvas = CGFloat(size)

let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSGraphicsContext.current?.imageInterpolation = .high

let bounds = CGRect(x: 0, y: 0, width: canvas, height: canvas)
let tile = NSBezierPath(roundedRect: bounds, xRadius: 232, yRadius: 232)
NSColor(calibratedWhite: 0.105, alpha: 1).setFill()
tile.fill()

// A soft top bevel replaces the previous gradient-and-glow treatment. The
// mark itself is what carries the identity.
let highlight = NSBezierPath()
highlight.move(to: CGPoint(x: 168, y: 842))
highlight.curve(
    to: CGPoint(x: 856, y: 842),
    controlPoint1: CGPoint(x: 328, y: 902),
    controlPoint2: CGPoint(x: 696, y: 902)
)
highlight.lineWidth = 5
highlight.lineCapStyle = .round
NSColor(calibratedWhite: 1, alpha: 0.16).setStroke()
highlight.stroke()

// Terminal prompt: a chevron and a cursor. Two glyphs, no frame, no texture;
// this keeps the mark readable at 16 px.
let prompt = NSBezierPath()
prompt.move(to: CGPoint(x: 318, y: 624))
prompt.line(to: CGPoint(x: 420, y: 544))
prompt.line(to: CGPoint(x: 318, y: 464))
prompt.lineWidth = 48
prompt.lineCapStyle = .round
prompt.lineJoinStyle = .round
NSColor(calibratedWhite: 1, alpha: 0.96).setStroke()
prompt.stroke()

let cursor = NSBezierPath(roundedRect: CGRect(x: 476, y: 468, width: 174, height: 48), xRadius: 24, yRadius: 24)
NSColor(calibratedWhite: 1, alpha: 0.68).setFill()
cursor.fill()

// Hairline border keeps the icon crisp on a light desktop without turning
// into a visible outline of its own.
let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 8), xRadius: 226, yRadius: 226)
border.lineWidth = 3
NSColor(calibratedWhite: 1, alpha: 0.10).setStroke()
border.stroke()

NSGraphicsContext.restoreGraphicsState()

let destination = URL(fileURLWithPath: output)
try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
try bitmap.representation(using: .png, properties: [:])!.write(to: destination)

if let icnsOutput {
    let representations: [(String, Int)] = [
        ("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128),
        ("ic08", 256), ("ic09", 512), ("ic10", 1024)
    ]
    var chunks = Data()
    let sourceImage = NSImage(cgImage: bitmap.cgImage!, size: NSSize(width: size, height: size))
    for (type, edge) in representations {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: edge, pixelsHigh: edge,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        sourceImage.draw(in: CGRect(x: 0, y: 0, width: edge, height: edge))
        NSGraphicsContext.restoreGraphicsState()
        let png = rep.representation(using: .png, properties: [:])!
        chunks.append(contentsOf: type.utf8)
        chunks.append(bigEndian(UInt32(png.count + 8)))
        chunks.append(png)
    }
    var icns = Data("icns".utf8)
    icns.append(bigEndian(UInt32(chunks.count + 8)))
    icns.append(chunks)
    let icnsURL = URL(fileURLWithPath: icnsOutput)
    try FileManager.default.createDirectory(at: icnsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try icns.write(to: icnsURL)
}

func bigEndian(_ value: UInt32) -> Data {
    var value = value.bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
