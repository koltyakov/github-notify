import AppKit

@main
struct AppIconTests {
    @MainActor
    static func main() throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        guard let original = NSImage(contentsOf: source),
              let image = ApplicationIcon.aboutImage(from: source) else {
            fatalError("Cannot load test logo")
        }
        precondition(image.size == NSSize(width: 64, height: 64))
        precondition(image.representations.map(\.pixelsWide) == [64, 128])
        precondition(image.representations.allSatisfy { $0.size == image.size })
        // Reproduce the previous shared About/system-image path as well.
        NSApplication.shared.applicationIconImage = original

        for scale in [1, 2] {
            for (name, candidate) in [("before", original), ("after", image)] {
                // Exercise the native image cell used for an About icon without
                // opening a window or launching the app's credential/polling code.
                let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
                view.imageScaling = .scaleProportionallyDown
                view.image = candidate
                let pixels = 64 * scale
                let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                )!
                let context = NSGraphicsContext(bitmapImageRep: bitmap)!
                context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                view.cell!.draw(withFrame: view.bounds, in: view)
                NSGraphicsContext.restoreGraphicsState()
                if name == "after" {
                    let selected = image.bestRepresentation(for: view.bounds, context: context, hints: nil)!
                    precondition(selected.pixelsWide == pixels, "Wrong representation at \(scale)x")
                    let expected = image.representations.first { $0.pixelsWide == pixels } as! NSBitmapImageRep
                    // Compare visible pixels, allowing color/alpha normalization
                    // by AppKit, but not low-resolution scaling or blank output.
                    var difference: CGFloat = 0
                    for y in 0..<pixels {
                        for x in 0..<pixels {
                            let actualColor = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                            let expectedColor = expected.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                            for (a, b) in zip(
                                [actualColor.redComponent, actualColor.greenComponent, actualColor.blueComponent],
                                [expectedColor.redComponent, expectedColor.greenComponent, expectedColor.blueComponent]
                            ) {
                                difference += abs(a * actualColor.alphaComponent - b * expectedColor.alphaComponent)
                            }
                            difference += abs(actualColor.alphaComponent - expectedColor.alphaComponent)
                        }
                    }
                    let meanDifference = difference / CGFloat(pixels * pixels * 4)
                    precondition(meanDifference < 0.01, "Rendered image differs at \(scale)x: \(meanDifference)")
                    print("PASS: native image cell renders the matching \(pixels)px representation at \(scale)x.")
                }
                let png = bitmap.representation(using: .png, properties: [:])!
                try png.write(to: output.appendingPathComponent("\(name)-\(scale)x.png"))
            }
        }
        let missing = source.deletingLastPathComponent().appendingPathComponent("missing-\(UUID()).png")
        precondition(ApplicationIcon.aboutImage(from: missing) == nil)
    }
}
