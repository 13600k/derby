#!/usr/bin/env swift
// Renders Derby's app icon (a routing fan-out on a rounded gradient tile) at
// every size macOS asks for, then leaves an .iconset for `iconutil`.
import AppKit
import Foundation

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./Derby.iconset"
try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let context = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    let scale = size / 1024.0
    let inset = 64.0 * scale
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let corner = rect.width * 0.2237   // macOS squircle proportion

    // Background gradient tile.
    let path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    context.saveGState()
    context.addPath(path)
    context.clip()
    let colors = [NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.42, alpha: 1).cgColor,
                  NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.20, alpha: 1).cgColor]
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors as CFArray, locations: [0, 1]) {
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: rect.minX, y: rect.maxY),
                                   end: CGPoint(x: rect.maxX, y: rect.minY),
                                   options: [])
    }

    // One inbound lane splitting into three outbound lanes.
    let midY = rect.midY
    let leftX = rect.minX + rect.width * 0.16
    let hubX = rect.minX + rect.width * 0.44
    let rightX = rect.maxX - rect.width * 0.16
    let spread = rect.height * 0.215
    let lane = rect.width * 0.052

    context.setLineCap(.round)
    context.setLineJoin(.round)

    // Inbound lane.
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
    context.setLineWidth(lane)
    context.move(to: CGPoint(x: leftX, y: midY))
    context.addLine(to: CGPoint(x: hubX, y: midY))
    context.strokePath()

    // Outbound lanes, tinted so the fan-out reads as three destinations.
    let laneColors = [
        NSColor(calibratedRed: 0.45, green: 0.80, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.62, green: 0.95, blue: 0.70, alpha: 1),
        NSColor(calibratedRed: 1.00, green: 0.72, blue: 0.45, alpha: 1),
    ]
    let targets = [midY + spread, midY, midY - spread]
    for (index, targetY) in targets.enumerated() {
        context.setStrokeColor(laneColors[index].cgColor)
        context.setLineWidth(lane * 0.9)
        context.move(to: CGPoint(x: hubX, y: midY))
        let control = CGPoint(x: hubX + (rightX - hubX) * 0.55, y: targetY)
        context.addCurve(to: CGPoint(x: rightX, y: targetY),
                         control1: control,
                         control2: CGPoint(x: hubX + (rightX - hubX) * 0.75, y: targetY))
        context.strokePath()

        context.setFillColor(laneColors[index].cgColor)
        let dot = lane * 1.25
        context.fillEllipse(in: CGRect(x: rightX - dot / 2, y: targetY - dot / 2, width: dot, height: dot))
    }

    // Routing hub.
    context.setFillColor(NSColor.white.cgColor)
    let hub = lane * 2.1
    context.fillEllipse(in: CGRect(x: hubX - hub / 2, y: midY - hub / 2, width: hub, height: hub))
    context.setFillColor(NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.24, alpha: 1).cgColor)
    let inner = hub * 0.42
    context.fillEllipse(in: CGRect(x: hubX - inner / 2, y: midY - inner / 2, width: inner, height: inner))

    context.restoreGState()

    // Subtle top highlight so the tile has depth.
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
    context.setLineWidth(2.5 * scale * 2)
    context.addPath(path)
    context.strokePath()
    context.restoreGState()

    image.unlockFocus()
    return image
}

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    let image = drawIcon(size: CGFloat(variant.pixels))
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("failed to render \(variant.name)\n".utf8))
        exit(1)
    }
    try png.write(to: URL(fileURLWithPath: "\(outputDirectory)/\(variant.name).png"))
}
print("wrote \(variants.count) icon sizes to \(outputDirectory)")
