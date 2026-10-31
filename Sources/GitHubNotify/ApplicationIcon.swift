import AppKit
import CoreImage

enum ApplicationIcon {
    static func aboutImage(from url: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: url),
              let source = NSBitmapImageRep(data: data)?.cgImage,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        let size = NSSize(width: 64, height: 64)
        let image = NSImage(size: size)
        let renderer = CIContext(options: [
            .useSoftwareRenderer: true,
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
        ])
        let input = CIImage(cgImage: source)
        // Give the About panel exactly the pixels it needs at 1x and Retina 2x.
        // Its image cell otherwise downsamples the full PNG with jagged edges.
        for scale in [1, 2] {
            let pixels = 64 * scale
            let scale = CGFloat(pixels) / CGFloat(source.height)
            let scaled = input.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale,
                kCIInputAspectRatioKey: CGFloat(source.height) / CGFloat(source.width),
            ])
            guard let rendered = renderer.createCGImage(
                scaled, from: CGRect(x: 0, y: 0, width: pixels, height: pixels),
                format: .RGBA8, colorSpace: colorSpace
            ) else { return nil }
            let representation = NSBitmapImageRep(cgImage: rendered)
            representation.size = size
            image.addRepresentation(representation)
        }
        return image
    }
}
