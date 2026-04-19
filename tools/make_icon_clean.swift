#!/usr/bin/env swift
// Alternate icon generator: same page + text bars as make_icon.swift, but
// WITHOUT the diagonal warm-yellow light beam. Writes a preview PNG plus
// a full .iconset so the result can be compared before promotion.
//
// Usage: swift tools/make_icon_clean.swift

import AppKit
import Foundation

let outDir = URL(fileURLWithPath: "AppIcon-clean.iconset")
let previewURL = URL(fileURLWithPath: "AppIcon-clean-preview.png")

try? FileManager.default.removeItem(at: outDir)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

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

    let radius = s * 0.2237
    NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                 xRadius: radius, yRadius: radius).addClip()

    // Paper gradient — slightly deeper bottom tone than the original so the
    // icon doesn't look flat after the beam is removed.
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

    // Three text bars — same geometry as the original.
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

    // No beam. Add a very subtle 1px inner edge so the white page has a
    // tiny bit of definition against light desktops.
    ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.04))
    ctx.setLineWidth(max(1, s * 0.004))
    let strokeInset = max(0.5, s * 0.002)
    let strokePath = NSBezierPath(
        roundedRect: CGRect(x: strokeInset, y: strokeInset,
                            width: s - strokeInset * 2, height: s - strokeInset * 2),
        xRadius: radius - strokeInset,
        yRadius: radius - strokeInset
    )
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

// Big preview image for side-by-side comparison.
try render(size: 1024).write(to: previewURL)

print("✓ wrote iconset to \(outDir.path)")
print("✓ wrote preview to \(previewURL.path)")
