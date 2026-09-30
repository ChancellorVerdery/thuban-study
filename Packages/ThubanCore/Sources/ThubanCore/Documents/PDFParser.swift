import Foundation
import CoreGraphics
import PDFKit

/// PDF files (PDFKit + CoreGraphics): text per page behind `pageBreak` blocks; embedded image XObjects found by
/// scanning each page's content stream and cropped out of a 2x render; pages with almost no text are treated as
/// scans (OCR through Vision, whole page kept as a figure when it carried no image of its own).
public struct PDFParser: DocumentParser {
    public static let kinds: [DocumentKind] = [.pdf]

    /// Render scale relative to PDF points (2 ⇒ 144 dpi).
    public static let renderScale: CGFloat = 2
    /// Pages rendered for the import agent (the first this many), at most this many pixels on the long side.
    static let maxPageImages = 60
    static let pageImageDimension = 1400
    /// Total figures kept per document; the rest are dropped with a warning.
    public static let maxFigures = 300

    /// Set to `false` to skip Vision OCR on scanned pages (faster, text-only).
    public var ocrEnabled: Bool

    public init(ocrEnabled: Bool = true) {
        self.ocrEnabled = ocrEnabled
    }

    public func parse(url: URL) async throws -> DocumentContent {
        guard let document = PDFDocument(url: url) else {
            throw ThubanError.unsupportedDocument("\"\(url.lastPathComponent)\" is not a readable PDF.")
        }
        if document.isLocked {
            throw ThubanError.unsupportedDocument("\"\(url.lastPathComponent)\" is password protected.")
        }
        var content = DocumentContent(pageCount: document.pageCount)
        var cut: CutFigure?
        for pageIndex in 0..<document.pageCount {
            try ParserSupport.checkCancellation()
            guard let page = document.page(at: pageIndex) else { cut = nil; continue }
            try await parsePage(page, number: pageIndex + 1, into: &content, cut: &cut)
        }
        if let cut { flush(cut, into: &content) }
        return content
    }

    /// A figure at the bottom of a page picture that the page break cut, held until the next page shows whether it
    /// continues there. `blockIndex` is where it goes among the content blocks (its own page).
    struct CutFigure {
        var picture: CGImage
        var rect: CGRect
        var page: Int
        var nearbyText: String
        var blockIndex: Int
    }

    /// Adds a held piece on its own when nothing continued it — if it is figure-sized (a sliver of a cut text line is
    /// not).
    private func flush(_ cut: CutFigure, into content: inout DocumentContent) {
        guard PageFigureFinder.isFigureSized(cut.rect), let crop = cut.picture.cropping(to: cut.rect), let png = ImageCodec.png(from: crop) else { return }
        insert(png: png, page: cut.page, nearbyText: cut.nearbyText, at: cut.blockIndex, into: &content)
    }

    private func insert(png: Data, page: Int, nearbyText: String, at blockIndex: Int, into content: inout DocumentContent) {
        guard content.figures.count < Self.maxFigures,
              let index = content.appendFigure(page: page, pngData: png, nearbyText: String(nearbyText.prefix(600)), force: true) else { return }
        content.blocks.insert(.image(index: index), at: min(blockIndex, content.blocks.count))
    }

    private func parsePage(_ page: PDFPage, number: Int, into content: inout DocumentContent, cut: inout CutFigure?) async throws {
        content.blocks.append(.pageBreak(number))
        let pageText = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var isScanned = pageText.count < VisionOCR.scannedPageThreshold
        var nearbyText = String(pageText.prefix(600))

        var render: PDFPageRender?
        if let pageRef = page.pageRef {
            do {
                render = try await ParserSupport.offloaded { try PDFPageRenderer.render(pageRef, scale: Self.renderScale) }
            } catch let error as ThubanError where error == .cancelled {
                throw error
            } catch {
                content.warnings.append("Page \(number): figures could not be extracted (\(error.localizedDescription)).")
            }
        }

        // A page printed as one picture (a reader's "print", a scan saved as PDF): its text layer is at most a print
        // footer, so it is read like a scan — watermarks removed, text recognized, figures found on the picture.
        if let render, let picture = render.onePicture {
            // The embedded picture itself: its edges are where the book was cut into pages (and the print header
            // outside it stays out).
            try await parsePicturePage(picture, number: number, cutEdges: true, into: &content, cut: &cut)
            return
        }
        if let held = cut { flush(held, into: &content) }
        cut = nil
        if isScanned, let render {
            var none: CutFigure?
            try await parsePicturePage(render.pageImage, number: number, cutEdges: false, into: &content, cut: &none)
            return
        }
        appendParagraphs(pageText, to: &content)

        guard let render else { return }
        if number <= Self.maxPageImages, let png = ImageCodec.png(from: render.pageImage, maxDimension: Self.pageImageDimension) {
            content.pageImages[number] = png
        }
        var figures = render.figures
        if figures.isEmpty, isScanned { figures = [render.pageImage] }
        for image in figures {
            guard content.figures.count < Self.maxFigures else {
                content.warnings.append("Figure limit reached; later figures were skipped.")
                return
            }
            guard let png = ImageCodec.png(from: image) else { continue }
            guard let index = content.appendFigure(page: number, pngData: png, nearbyText: nearbyText, force: isScanned) else { continue }
            content.blocks.append(.image(index: index))
        }
    }

    /// A scanned or pictured page: watermarks off, OCR on the clean picture, each figure cropped on its own (never
    /// the whole page as one figure).
    private func parsePicturePage(
        _ pageImage: CGImage, number: Int, cutEdges: Bool, into content: inout DocumentContent, cut: inout CutFigure?
    ) async throws {
        let cleaned = (try? await ParserSupport.offloaded { WatermarkRemover.clean(pageImage) }) ?? nil
        let page = cleaned ?? pageImage
        let lines = ocrEnabled ? try await VisionOCR.recognizeLines(in: page) : []
        appendParagraphs(lines.map(\.text).joined(separator: "\n"), to: &content)
        if number <= Self.maxPageImages, let png = ImageCodec.png(from: page, maxDimension: Self.pageImageDimension) {
            content.pageImages[number] = png
        }
        guard let bitmap = PageBitmap(page) else { return }
        let found = try await ParserSupport.offloaded { PageFigureFinder.figures(in: bitmap, lines: lines, cutEdges: cutEdges) }
        var previousCut = cut
        cut = nil
        for (position, figure) in found.enumerated() {
            // The lower half of a figure the page break cut: joined to its upper half on the previous page, where the
            // figure goes (its problem is there).
            if position == 0, figure.touchesTop, let previous = previousCut {
                previousCut = nil
                let joinedHeight = (CGFloat(previous.picture.height) - previous.rect.minY) + figure.rect.maxY
                let joinedRect = CGRect(x: 0, y: 0, width: max(previous.rect.width, figure.rect.width), height: joinedHeight)
                if PageFigureFinder.isFigureSized(joinedRect),
                   let joined = FigureStitcher.stitch(upper: previous.picture, upperRect: previous.rect, lower: page, lowerRect: figure.rect),
                   let png = ImageCodec.png(from: joined) {
                    let nearby = ([figure.caption].compactMap { $0 } + [previous.nearbyText]).joined(separator: "\n")
                    insert(png: png, page: previous.page, nearbyText: nearby, at: previous.blockIndex, into: &content)
                    continue
                }
                flush(previous, into: &content)
            }
            // A piece cut at the top that continues nothing is kept only if it is a figure on its own.
            if figure.touchesTop, !PageFigureFinder.isFigureSized(figure.rect) { continue }
            guard content.figures.count < Self.maxFigures else {
                content.warnings.append("Figure limit reached; later figures were skipped.")
                return
            }
            guard let crop = page.cropping(to: figure.rect), let png = ImageCodec.png(from: crop) else { continue }
            // The caption, then the text just above the figure (the problem it belongs to).
            let above = lines.filter { $0.rect.maxY <= figure.rect.minY + 4 && $0.rect.maxY >= figure.rect.minY - 260 }.map(\.text)
            let nearby = ([figure.caption].compactMap { $0 } + above).joined(separator: "\n")
            if figure.touchesBottom, position == found.count - 1 {
                // Held: the next page may continue it.
                cut = CutFigure(picture: page, rect: figure.rect, page: number, nearbyText: nearby, blockIndex: content.blocks.count)
                continue
            }
            insert(png: png, page: number, nearbyText: nearby, at: content.blocks.count, into: &content)
        }
        if let previousCut { flush(previousCut, into: &content) }
    }

    private func appendParagraphs(_ text: String, to content: inout DocumentContent) {
        content.blocks.append(contentsOf: ParserSupport.paragraphs(from: text).map { ContentBlock.paragraph($0) })
    }
}

/// A rendered page plus the embedded images cropped from it.
struct PDFPageRender {
    let pageImage: CGImage
    let figures: [CGImage]

    /// The picture that covers nearly all of the page, when the page is one picture (a reader's print, a scan).
    var onePicture: CGImage? {
        let pageArea = Double(pageImage.width * pageImage.height)
        return figures.first { Double($0.width * $0.height) >= 0.7 * pageArea }
    }
}

/// Renders a `CGPDFPage` and crops its image XObjects.
enum PDFPageRenderer {
    /// Images whose rendered size is under this many pixels on either side are ignored (bullets, rules, icons).
    static let minimumFigureSide: CGFloat = 40
    /// Per-page cap on extracted images.
    static let maxFiguresPerPage = 12

    static func render(_ page: CGPDFPage, scale: CGFloat) throws -> PDFPageRender {
        let box = page.getBoxRect(.cropBox)
        let rotated = page.rotationAngle % 180 != 0
        let size = CGSize(width: rotated ? box.height : box.width, height: rotated ? box.width : box.height)
        let width = Int((size.width * scale).rounded(.up))
        let height = Int((size.height * scale).rounded(.up))
        guard let context = ImageCodec.rgbaContext(width: width, height: height) else {
            throw ThubanError.parse("Could not allocate a \(width)×\(height) canvas for the page.")
        }
        let transform = page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true)
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        context.concatenate(transform)
        context.interpolationQuality = .high
        context.drawPDFPage(page)
        context.restoreGState()
        guard let pageImage = context.makeImage() else {
            throw ThubanError.parse("Page rendering produced no image.")
        }
        let rects = PDFContentScanner.imageRects(in: page)
            .map { $0.applying(transform).applying(CGAffineTransform(scaleX: scale, y: scale)) }
        let figures = crop(rects, from: pageImage)
        return PDFPageRender(pageImage: pageImage, figures: figures)
    }

    /// Crops the given device-space rects (origin bottom-left) out of `image`, dropping tiny and duplicate ones.
    private static func crop(_ rects: [CGRect], from image: CGImage) -> [CGImage] {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var seen: [CGRect] = []
        var figures: [CGImage] = []
        for rect in rects {
            let flipped = CGRect(x: rect.minX, y: CGFloat(image.height) - rect.maxY, width: rect.width, height: rect.height)
            let clipped = flipped.standardized.intersection(bounds).integral
            guard clipped.width >= minimumFigureSide, clipped.height >= minimumFigureSide else { continue }
            guard !seen.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(clipped) && clipped.insetBy(dx: -2, dy: -2).contains($0) }) else { continue }
            seen.append(clipped)
            if let cropped = image.cropping(to: clipped) { figures.append(cropped) }
            if figures.count >= maxFiguresPerPage { break }
        }
        return figures
    }
}

/// Walks a page's content stream with `CGPDFScanner`, tracking the CTM, to find where image XObjects are drawn.
/// Form XObjects are entered (their `/Matrix` applied) so images nested in forms are found too.
enum PDFContentScanner {
    /// Rectangles in the page's user space where images are painted, in drawing order.
    static func imageRects(in page: CGPDFPage) -> [CGRect] {
        guard let table = CGPDFOperatorTableCreate() else { return [] }
        CGPDFOperatorTableSetCallback(table, "q") { _, info in PDFContentScanner.state(info)?.pushGraphicsState() }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in PDFContentScanner.state(info)?.popGraphicsState() }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in PDFContentScanner.state(info)?.concatenate(scanner) }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in PDFContentScanner.state(info)?.drawXObject(scanner) }

        defer { CGPDFOperatorTableRelease(table) }
        let scanState = ScanState(table: table)
        let stream = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(stream) }
        scanState.scan(stream)
        return scanState.rects
    }

    fileprivate static func state(_ info: UnsafeMutableRawPointer?) -> ScanState? {
        guard let info else { return nil }
        return Unmanaged<ScanState>.fromOpaque(info).takeUnretainedValue()
    }

    /// Mutable scanning state handed to the C callbacks through the `info` pointer.
    final class ScanState {
        private let table: CGPDFOperatorTableRef
        private var ctm = CGAffineTransform.identity
        private var stack: [CGAffineTransform] = []
        private var streams: [CGPDFContentStreamRef] = []
        private var depth = 0
        private(set) var rects: [CGRect] = []

        init(table: CGPDFOperatorTableRef) {
            self.table = table
        }

        func scan(_ stream: CGPDFContentStreamRef) {
            streams.append(stream)
            defer { streams.removeLast() }
            let info = Unmanaged.passUnretained(self).toOpaque()
            let scanner = CGPDFScannerCreate(stream, table, info)
            _ = CGPDFScannerScan(scanner)
            CGPDFScannerRelease(scanner)
        }

        func pushGraphicsState() { stack.append(ctm) }

        func popGraphicsState() { if let previous = stack.popLast() { ctm = previous } }

        func concatenate(_ scanner: CGPDFScannerRef) {
            guard let matrix = popMatrix(scanner) else { return }
            ctm = matrix.concatenating(ctm)
        }

        func drawXObject(_ scanner: CGPDFScannerRef) {
            var namePointer: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &namePointer), let name = namePointer, let current = streams.last,
                  let object = CGPDFContentStreamGetResource(current, "XObject", name) else { return }
            var streamRef: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &streamRef), let stream = streamRef,
                  let dictionary = CGPDFStreamGetDictionary(stream) else { return }
            var subtypePointer: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtypePointer), let subtype = subtypePointer else { return }
            switch String(cString: subtype) {
            case "Image":
                rects.append(CGRect(x: 0, y: 0, width: 1, height: 1).applying(ctm))
            case "Form":
                enterForm(stream, dictionary: dictionary)
            default:
                break
            }
        }

        private func enterForm(_ stream: CGPDFStreamRef, dictionary: CGPDFDictionaryRef) {
            guard depth < 6, let parent = streams.last else { return }
            depth += 1
            defer { depth -= 1 }
            let saved = ctm
            let savedStack = stack
            var array: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dictionary, "Matrix", &array), let matrix = array.flatMap(Self.matrix(from:)) {
                ctm = matrix.concatenating(ctm)
            }
            let formStream = CGPDFContentStreamCreateWithStream(stream, dictionary, parent)
            scan(formStream)
            CGPDFContentStreamRelease(formStream)
            ctm = saved
            stack = savedStack
        }

        /// Pops the six operands of `cm` (last operand first).
        private func popMatrix(_ scanner: CGPDFScannerRef) -> CGAffineTransform? {
            var values = [CGPDFReal](repeating: 0, count: 6)
            for index in stride(from: 5, through: 0, by: -1) {
                guard CGPDFScannerPopNumber(scanner, &values[index]) else { return nil }
            }
            return CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
        }

        private static func matrix(from array: CGPDFArrayRef) -> CGAffineTransform? {
            guard CGPDFArrayGetCount(array) == 6 else { return nil }
            var values = [CGPDFReal](repeating: 0, count: 6)
            for index in 0..<6 {
                guard CGPDFArrayGetNumber(array, index, &values[index]) else { return nil }
            }
            return CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
        }
    }
}
