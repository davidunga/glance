#!/usr/bin/env swift
// Generates an .iconset directory with all the sizes macOS expects.
// Usage: swift tools/make_icon.swift [output.iconset]
//
// The icon IS a page: a near-white rounded square with three text-line bars
// and a soft warm diagonal beam of light catching the document.

import AppKit
import Foundation

let outDir = CommandLine.arguments.dropFirst().first.map(URL.init(fileURLWithPath:))
    ?? URL(fileURLWithPath: "glance.iconset")

try? FileManager.default.removeItem(at: outDir)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(size px: Int) -> Data {
    let s = CGFloat(px)

    // Draw directly into an NSBitmapImageRep — avoids NSImage backing-store
    // quirks at small sizes (tiffRepresentation fails at 16×16).
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

    // Big Sur–style rounded square clip — this is the page outline.
    let radius = s * 0.2237
    NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                 xRadius: radius, yRadius: radius).addClip()

    // The page IS the icon. A barely-there top-to-bottom paper gradient
    // gives it a hint of depth without breaking the "single sheet" read.
    let paper = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1.0), // top
            CGColor(red: 0.945, green: 0.945, blue: 0.955, alpha: 1.0), // bottom
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        paper,
        start: CGPoint(x: 0, y: s),
        end:   CGPoint(x: 0, y: 0),
        options: []
    )

    // Three text bars, centered vertically. Slightly varied widths so it
    // reads as text rather than abstract stripes.
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

    // Diagonal light beam crossing the page. Drawn in a rotated coordinate
    // system so we can use a horizontal gradient as the cross-section.
    ctx.saveGState()
    ctx.translateBy(x: s / 2, y: s / 2)
    ctx.rotate(by: -CGFloat.pi / 4) // 45° down-right

    let beamWidth = s * 0.34
    let beamLength = s * 1.7
    let beamRect = CGRect(
        x: -beamWidth / 2,
        y: -beamLength / 2,
        width: beamWidth,
        height: beamLength
    )

    ctx.clip(to: beamRect)
    let beam = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(red: 1.000, green: 0.910, blue: 0.560, alpha: 0.00),
            CGColor(red: 1.000, green: 0.910, blue: 0.560, alpha: 0.55),
            CGColor(red: 1.000, green: 0.910, blue: 0.560, alpha: 0.00),
        ] as CFArray,
        locations: [0, 0.5, 1]
    )!
    ctx.drawLinearGradient(
        beam,
        start: CGPoint(x: -beamWidth / 2, y: 0),
        end:   CGPoint(x:  beamWidth / 2, y: 0),
        options: []
    )
    ctx.restoreGState()

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
    print("  \(entry.name)  (\(entry.px)×\(entry.px))")
}
print("✓ wrote \(entries.count) icon sizes to \(outDir.path)")
