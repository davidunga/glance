#!/usr/bin/env swift
// Squircle variant — same design as make_icon_bordered.swift but with an
// Apple-style superellipse ("squircle") outline instead of circular rounded
// corners. This matches the shape of stock macOS app icons.
//
// Usage: swift tools/make_icon_squircle.swift

import AppKit
import Foundation

let outDir = URL(fileURLWithPath: "AppIcon-squircle.iconset")
let previewURL = URL(fileURLWithPath: "AppIcon-squircle-preview.png")

try? FileManager.default.removeItem(at: outDir)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

/// Superellipse with exponent ≈ 5 — visually indistinguishable from Apple's
/// iOS/macOS icon squircle. Sampled as a fine polyline (~720 segments at
/// 1024px) so even thick strokes render without visible facets.
func squirclePath(in rect: CGRect, exponent n: CGFloat = 5, steps: Int = 720) -> NSBezierPath {
    let path = NSBezierPath()
    let cx = rect.midX
    let cy = rect.midY
    let rx = rect.width / 2
    let ry = rect.height / 2
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let cosT = cos(t)
        let sinT = sin(t)
        let x = cx + rx * copysign(pow(abs(cosT), 2 / n), cosT)
        let y = cy + ry * copysign(pow(abs(sinT), 2 / n), sinT)
        if i == 0 {
            path.move(to: CGPoint(x: x, y: y))
        } else {
            path.line(to: CGPoint(x: x, y: y))
        }
    }
    path.close()
    return path
}

func render(size px: Int) -> Data {
    let s = CGFloat(px)

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 32
    ) else { fatalError("NSBitmapImageRep failed at \(px)px") }

    guard let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("NSGraphicsContext failed at \(px)px")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx
    defer { NSGraphicsContext.restoreGraphicsState() }

    let ctx = nsCtx.cgContext
    let cs = CGColorSpaceCreateDeviceRGB()
    let fullRect = CGRect(x: 0, y: 0, width: s, height: s)

    NSGraphicsContext.current?.saveGraphicsState()
    squirclePath(in: fullRect).addClip()

    let paper = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1.0),
            CGColor(red: 0.930, green: 0.932, blue: 0.945, alpha: 1.0),
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        paper,
        start: CGPoint(x: 0, y: s),
        end:   CGPoint(x: 0, y: 0),
        options: []
    )

    let barColor = NSColor(red: 0.62, green: 0.64, blue: 0.69, alpha: 1.0)
    let barInsetX = s * 0.17
    let barAreaWidth = s - barInsetX * 2
    let barHeight = s * 0.065
    let lineGap = s * 0.085
    let totalHeight = barHeight * 3 + lineGap * 2
    let centerY = s * 0.50
    let firstBarY = centerY + totalHeight / 2 - barHeight

    let widths: [CGFloat] = [0.95, 1.00, 0.70]
    for (i, w) in widths.enumerated() {
        let y = firstBarY - CGFloat(i) * (barHeight + lineGap)
        let rect = CGRect(x: barInsetX, y: y, width: barAreaWidth * w, height: barHeight)
        let path = NSBezierPath(roundedRect: rect, xRadius: barHeight / 2, yRadius: barHeight / 2)
        barColor.setFill()
        path.fill()
    }

    NSGraphicsContext.current?.restoreGraphicsState()

    // Thin border in bar color, stroked along the squircle edge.
    let strokeWidth = max(1, s * 0.012)
    let inset = strokeWidth / 2
    let strokePath = squirclePath(in: fullRect.insetBy(dx: inset, dy: inset))
    strokePath.lineWidth = strokeWidth
    strokePath.lineJoinStyle = .round
    barColor.setStroke()
    strokePath.stroke()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encode failed at \(px)px")
    }
    return png
}

let entries: [(name: String, px: Int)] = [
    ("icon_16x16.png",      16),
    ("icon_16x16@2x.png",   32),
    ("icon_32x32.png",      32),
    ("icon_32x32@2x.png",   64),
    ("icon_128x128.png",   128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",   256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",   512),
    ("icon_512x512@2x.png", 1024),
]

for entry in entries {
    let data = render(size: entry.px)
    try data.write(to: outDir.appendingPathComponent(entry.name))
}

try render(size: 1024).write(to: previewURL)

print("✓ wrote iconset to \(outDir.path)")
print("✓ wrote preview to \(previewURL.path)")
