import AppKit
import Foundation

func generateIcons(source: URL, destination: URL) throws {
    guard let logo = NSImage(contentsOf: source), logo.isValid else {
        throw NSError(domain: "GitHubNotify.Icons", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Cannot load logo at \(source.path)"])
    }
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    // Render at 2x for the 18-point menu-bar image.
    let size = NSSize(width: 36, height: 36)
    let badges: [(String, NSColor?)] = [
        ("base", nil),
        ("notice", NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)),
        ("warn", NSColor(srgbRed: 1, green: 0.80, blue: 0, alpha: 1)),
        ("error", NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)),
    ]
    for (state, color) in badges {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw NSError(domain: "GitHubNotify.Icons", code: 2)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        logo.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        if let color {
            let badge = NSRect(x: 18, y: 0, width: 18, height: 18)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: badge).fill()
            color.setFill()
            NSBezierPath(ovalIn: badge.insetBy(dx: 1, dy: 1)).fill()
            let mark = NSBezierPath()
            mark.lineWidth = 2
            mark.lineCapStyle = .round
            if state == "warn" {
                NSColor.black.setStroke()
                mark.move(to: NSPoint(x: 27, y: 13))
                mark.line(to: NSPoint(x: 27, y: 8))
                mark.stroke()
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 26, y: 3.5, width: 2, height: 2)).fill()
            } else if state == "error" {
                NSColor.white.setStroke()
                mark.move(to: NSPoint(x: 24, y: 6))
                mark.line(to: NSPoint(x: 30, y: 12))
                mark.move(to: NSPoint(x: 24, y: 12))
                mark.line(to: NSPoint(x: 30, y: 6))
                mark.stroke()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "GitHubNotify.Icons", code: 3)
        }
        try png.write(to: destination.appendingPathComponent("status-\(state).png"))
    }
}

do {
    guard CommandLine.arguments.count == 3 else {
        throw NSError(domain: "GitHubNotify.Icons", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "Usage: swift scripts/generate-status-icons.swift <logo.png> <output directory>",
        ])
    }
    try generateIcons(
        source: URL(fileURLWithPath: CommandLine.arguments[1]),
        destination: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    )
} catch {
    FileHandle.standardError.write(Data("Icon generation failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
