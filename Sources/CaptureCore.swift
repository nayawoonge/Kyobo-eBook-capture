import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

struct CaptureError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct CaptureRegion {
    let displayID: CGDirectDisplayID
    let sourceRect: CGRect // Display-local, top-left origin, in points.
    let screenFrame: CGRect // AppKit global coordinates, used to detect display changes.
    let scale: CGFloat

    static func topLeftRect(_ rect: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    static func quartzPoint(_ point: CGPoint, screenFrame: CGRect, primaryTop: CGFloat) -> CGPoint {
        CGPoint(x: screenFrame.minX + point.x, y: primaryTop - screenFrame.minY - point.y)
    }
}

func pngData(_ image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw CaptureError("PNG 저장기를 만들지 못했습니다.")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CaptureError("PNG 인코딩에 실패했습니다.") }
    return data as Data
}

// Stream pages to disk, so memory use does not grow with the entire book.
final class PDFWriter {
    private var context: CGContext?
    private let temporaryURL: URL
    let url: URL
    private(set) var count = 0

    init(url: URL) throws {
        self.url = url
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw CaptureError("같은 이름의 PDF가 이미 있습니다. 다른 저장 이름을 선택하세요.")
        }
        temporaryURL = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial.pdf")
        guard let consumer = CGDataConsumer(url: temporaryURL as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw CaptureError("PDF 파일을 만들 수 없습니다. 저장 폴더와 여유 공간을 확인하세요.")
        }
        self.context = context
    }

    func append(_ image: CGImage, size: CGSize) {
        guard let context else { return }
        var box = CGRect(origin: .zero, size: size)
        let media = NSData(bytes: &box, length: MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextMediaBox as String: media] as CFDictionary)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(box)
        context.draw(image, in: box)
        context.endPDFPage()
        count += 1
    }

    func finish() throws -> URL? {
        context?.closePDF()
        context = nil
        guard count > 0 else {
            try? FileManager.default.removeItem(at: temporaryURL)
            return nil
        }
        guard let document = CGPDFDocument(temporaryURL as CFURL), document.numberOfPages == count else {
            throw CaptureError("PDF 검증에 실패했습니다. PNG 원본으로 다시 PDF를 만들 수 있습니다.")
        }
        // moveItem refuses to replace an existing destination.
        try FileManager.default.moveItem(at: temporaryURL, to: url)
        return url
    }

    deinit { context?.closePDF() }
}

struct CaptureResult {
    let directory: URL
    let pdf: URL?
    let saved: Int
    let message: String
    let completed: Bool
}

@MainActor
final class CaptureEngine {
    static func wait(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    // Injectable I/O lets tests verify cancellation and page order without capturing the user's screen.
    func run(root: URL, pages: Int, interval: Double, pageSize: CGSize,
             capture: () async throws -> CGImage,
             turn: () throws -> Void,
             validate: () throws -> Void,
             wait: (Double) async throws -> Void = CaptureEngine.wait,
             progress: (Int) -> Void = { _ in }) async throws -> CaptureResult {
        guard (1...5000).contains(pages), interval.isFinite, (0.3...30).contains(interval),
              pageSize.width > 0, pageSize.height > 0 else {
            throw CaptureError("페이지 수 또는 대기 시간 설정이 올바르지 않습니다.")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = root.appendingPathComponent("capture-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let writer = try PDFWriter(url: directory.appendingPathComponent("book.pdf"))
        var previous: SHA256.Digest?
        var message = "완료"
        var completed = false

        do {
            for index in 1...pages {
                try Task.checkCancellation()
                try validate()
                var image = try await capture()
                try Task.checkCancellation()
                try validate()
                var data = try pngData(image)
                var digest = SHA256.hash(data: data)
                // A slow page turn gets two extra waits, never an extra page-turn event.
                for _ in 0..<2 where previous == digest {
                    try await wait(interval)
                    try Task.checkCancellation()
                    try validate()
                    image = try await capture()
                    try Task.checkCancellation()
                    try validate()
                    data = try pngData(image)
                    digest = SHA256.hash(data: data)
                }
                guard previous != digest else {
                    throw CaptureError("같은 화면이 반복되어 중단했습니다. 마지막 페이지이거나 페이지 넘김이 작동하지 않을 수 있습니다.")
                }
                let path = directory.appendingPathComponent(String(format: "%04d.png", index))
                try data.write(to: path, options: .atomic)
                writer.append(image, size: pageSize)
                previous = digest
                progress(index)
                if index < pages {
                    try Task.checkCancellation()
                    try validate()
                    try turn()
                    try await wait(interval)
                }
            }
            completed = true
        } catch is CancellationError {
            message = "사용자가 중지했습니다."
        } catch {
            message = error.localizedDescription
        }

        let pdf = try writer.finish()
        let manifest: [String: Any] = [
            "requestedPages": pages, "savedPages": writer.count, "completed": completed,
            "message": message, "intervalSeconds": interval,
            "pageWidthPoints": pageSize.width, "pageHeightPoints": pageSize.height,
            "createdAt": ISO8601DateFormatter().string(from: Date())
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("session.json"), options: .atomic)
        return CaptureResult(directory: directory, pdf: pdf, saved: writer.count, message: message, completed: completed)
    }
}

func imageFiles(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        .filter {
            ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) &&
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: [.numeric, .literal]) == .orderedAscending }
}

func combineImages(_ files: [URL], into output: URL) throws {
    guard !files.isEmpty else { throw CaptureError("폴더에 PNG 또는 JPEG 이미지가 없습니다.") }
    let writer = try PDFWriter(url: output)
    for file in files {
        try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw CaptureError("이미지를 읽을 수 없습니다: \(file.lastPathComponent)")
            }
            writer.append(image, size: CGSize(width: image.width, height: image.height))
        }
    }
    _ = try writer.finish()
}
