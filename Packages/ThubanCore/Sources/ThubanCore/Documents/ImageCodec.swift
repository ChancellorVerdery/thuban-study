import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Image decoding/encoding shared by the parsers: anything ImageIO can read becomes a PNG, and figures are
/// downsampled so the largest side never exceeds `maxFigureDimension` (Claude's vision input works best under
/// ~1600 px and the PNGs are stored on disk).
enum ImageCodec {
    static let maxFigureDimension = 2000

    /// Decodes `data` (PNG, JPEG, HEIC, TIFF, GIF, BMP, WebP …) into a CGImage.
    static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    /// Decodes the image file at `url`.
    static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    /// Encodes `image` as PNG, downsampling first when it is larger than `maxDimension` on its longest side.
    static func png(from image: CGImage, maxDimension: Int = maxFigureDimension) -> Data? {
        let scaled = downsample(image, maxDimension: maxDimension) ?? image
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, scaled, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Re-encodes arbitrary image bytes as PNG; `nil` when ImageIO cannot decode them (e.g. EMF/WMF/SVG).
    static func pngData(fromImageData data: Data) -> Data? {
        guard let image = image(from: data) else { return nil }
        return png(from: image)
    }

    /// Returns a scaled copy when either side exceeds `maxDimension`, else `nil`.
    static func downsample(_ image: CGImage, maxDimension: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > maxDimension, longest > 0 else { return nil }
        let factor = Double(maxDimension) / Double(longest)
        let width = max(1, Int(Double(image.width) * factor))
        let height = max(1, Int(Double(image.height) * factor))
        guard let context = rgbaContext(width: width, height: height) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// A white-filled 8-bit RGBA bitmap context.
    static func rgbaContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }
}

/// Text recognition through Vision, used for scanned PDF pages and image documents.
enum VisionOCR {
    /// Pages with fewer readable characters than this are treated as scans and sent to OCR.
    static let scannedPageThreshold = 20

    /// Recognizes text in `image` (accurate mode, language correction on). Lines are joined with newlines, in
    /// top-to-bottom reading order. Returns an empty string when nothing is found.
    static func recognizeText(in image: CGImage) async throws -> String {
        try await ParserSupport.offloaded {
            try recognizeTextSync(in: image)
        }
    }

    private static func recognizeTextSync(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw ThubanError.parse("Text recognition failed: \(error.localizedDescription)")
        }
        let observations = request.results ?? []
        let ordered = observations.sorted { lhs, rhs in
            // Vision's origin is bottom-left; higher `y` means nearer the top of the page.
            let dy = lhs.boundingBox.midY - rhs.boundingBox.midY
            if abs(dy) > 0.008 { return dy > 0 }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
        return ordered
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
