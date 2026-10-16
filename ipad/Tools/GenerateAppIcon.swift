import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count >= 2 else {
    fputs("usage: GenerateAppIcon.swift <output.png>\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)

let side = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: side,
    height: side,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Could not create CGContext")
}

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

let bounds = CGRect(x: 0, y: 0, width: side, height: side)

let background = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        color(0.035, 0.075, 0.13),
        color(0.025, 0.24, 0.31)
    ] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(
    background,
    start: CGPoint(x: 90, y: 930),
    end: CGPoint(x: 900, y: 80),
    options: []
)

let center = CGPoint(x: 512, y: 508)
let radius: CGFloat = 292

func point(angleDegrees: CGFloat, radius: CGFloat) -> CGPoint {
    let angle = angleDegrees * .pi / 180
    return CGPoint(
        x: center.x + cos(angle) * radius,
        y: center.y + sin(angle) * radius
    )
}

// Main analyzer/gauge arc.
context.setStrokeColor(color(0.23, 0.88, 0.84))
context.setLineWidth(44)
context.setLineCap(.butt)
context.addArc(
    center: center,
    radius: radius,
    startAngle: 205 * .pi / 180,
    endAngle: 335 * .pi / 180,
    clockwise: false
)
context.strokePath()

context.setStrokeColor(color(0.7, 0.9, 0.92, 0.42))
context.setLineWidth(8)
context.addArc(
    center: center,
    radius: radius - 45,
    startAngle: 205 * .pi / 180,
    endAngle: 335 * .pi / 180,
    clockwise: false
)
context.strokePath()

// Gauge ticks.
for index in 0...12 {
    let angle = 205 + (130 * CGFloat(index) / 12)
    let major = index % 3 == 0
    let inner = point(
        angleDegrees: angle,
        radius: radius - (major ? 38 : 25)
    )
    let outer = point(angleDegrees: angle, radius: radius + 5)
    context.setStrokeColor(color(0.92, 0.98, 0.99, 0.95))
    context.setLineWidth(major ? 16 : 10)
    context.move(to: inner)
    context.addLine(to: outer)
    context.strokePath()
}

// Needle.
let needleAngle: CGFloat = 287
context.setStrokeColor(color(1.0, 0.61, 0.17))
context.setLineWidth(28)
context.setLineCap(.round)
context.move(to: point(angleDegrees: needleAngle + 180, radius: 48))
context.addLine(to: point(angleDegrees: needleAngle, radius: 232))
context.strokePath()

context.setFillColor(color(0.94, 0.98, 0.99))
context.fillEllipse(in: CGRect(x: center.x - 43, y: center.y - 43, width: 86, height: 86))
context.setFillColor(color(0.035, 0.16, 0.21))
context.fillEllipse(in: CGRect(x: center.x - 18, y: center.y - 18, width: 36, height: 36))

// Analysis waveform / CAN samples.
let waveform: [CGPoint] = [
    CGPoint(x: 250, y: 350),
    CGPoint(x: 330, y: 350),
    CGPoint(x: 370, y: 405),
    CGPoint(x: 420, y: 282),
    CGPoint(x: 475, y: 372),
    CGPoint(x: 535, y: 372),
    CGPoint(x: 575, y: 437),
    CGPoint(x: 628, y: 310),
    CGPoint(x: 675, y: 378),
    CGPoint(x: 775, y: 378)
]
context.setStrokeColor(color(0.92, 0.98, 0.99))
context.setLineWidth(18)
context.setLineJoin(.round)
context.setLineCap(.round)
context.move(to: waveform[0])
for point in waveform.dropFirst() {
    context.addLine(to: point)
}
context.strokePath()

for point in [waveform[1], waveform[5], waveform[9]] {
    context.setFillColor(color(0.23, 0.88, 0.84))
    context.fillEllipse(in: CGRect(x: point.x - 15, y: point.y - 15, width: 30, height: 30))
}

// Wireless/BLE hint without using a vendor logo.
let radioCenter = CGPoint(x: 744, y: 690)
for (radius, width, alpha) in [(58.0, 15.0, 0.95), (92.0, 17.0, 0.82)] {
    context.setStrokeColor(color(0.92, 0.98, 0.99, CGFloat(alpha)))
    context.setLineWidth(CGFloat(width))
    context.addArc(
        center: radioCenter,
        radius: CGFloat(radius),
        startAngle: -55 * .pi / 180,
        endAngle: 55 * .pi / 180,
        clockwise: false
    )
    context.strokePath()
}
context.setFillColor(color(0.23, 0.88, 0.84))
context.fillEllipse(in: CGRect(x: radioCenter.x - 12, y: radioCenter.y - 12, width: 24, height: 24))

guard let cgImage = context.makeImage() else {
    fatalError("Could not make icon image")
}
let rep = NSBitmapImageRep(cgImage: cgImage)
guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode PNG")
}
try png.write(to: outputURL, options: .atomic)
print("Generated app icon at \(outputURL.path)")
