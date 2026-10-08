import AppKit
import CoreText

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CaptureError("TEST: " + message) }
}

private func testImage(_ index: Int) throws -> CGImage {
    guard let context = CGContext(data: nil, width: 600, height: 800, bitsPerComponent: 8, bytesPerRow: 2400,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw CaptureError("Test bitmap failed")
    }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
    context.setFillColor(CGColor(red: 0.90, green: 0.2, blue: 0.13, alpha: 1))
    context.fill(CGRect(x: 0, y: 740, width: 600, height: 60))
    context.setFillColor(CGColor(red: 0.12, green: 0.3, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 600, height: 60))
    let lines = ["PAGE \(index)", "TOP: RED / BOTTOM: BLUE", "Retina sample: 600 x 800 px", "PDF size: 300 x 400 pt", "PageCapture export check"]
    for (lineIndex, text) in lines.enumerated() {
        let font = CTFontCreateWithName("Helvetica" as CFString, lineIndex == 0 ? 42 : 23, nil)
        let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.12, alpha: 1)])
        context.textPosition = CGPoint(x: 35, y: 640 - lineIndex * 75)
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
    }
    return context.makeImage()!
}

@MainActor
func runSelfTests(directory: URL) async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let images = try (1...3).map(testImage)
    let size = CGSize(width: 300, height: 400)
    let engine = CaptureEngine()
    let noWait: (Double) async throws -> Void = { _ in }

    var captures = 0
    var turns = 0
    let normal = try await engine.run(root: directory, pages: 3, interval: 1, pageSize: size, capture: {
        defer { captures += 1 }; return images[captures]
    }, turn: { turns += 1 }, validate: {}, wait: noWait)
    try require(normal.completed && normal.saved == 3 && turns == 2, "three pages must send only two turn events")
    guard let pdf = normal.pdf, let document = CGPDFDocument(pdf as CFURL) else { throw CaptureError("No test PDF") }
    try require(document.numberOfPages == 3, "PDF page count")
    try require(document.page(at: 1)!.getBoxRect(.mediaBox).size == size, "Retina logical page dimensions")
    let original = try Data(contentsOf: pdf)
    do { _ = try PDFWriter(url: pdf); throw CaptureError("TEST: overwrite was allowed") }
    catch let error as CaptureError { try require(error.message.contains("이미"), "existing PDF should be refused") }
    let afterRefusal = try Data(contentsOf: pdf)
    try require(afterRefusal == original, "existing PDF changed")
    print("PASS: page order, final-page input, PDF dimensions, no overwrite")

    turns = 0
    let one = try await engine.run(root: directory, pages: 1, interval: 1, pageSize: size,
                                  capture: { images[0] }, turn: { turns += 1 }, validate: {}, wait: noWait)
    try require(one.completed && one.saved == 1 && turns == 0, "one-page test must not turn")
    print("PASS: one-page test")

    let stopped = try await engine.run(root: directory, pages: 3, interval: 1, pageSize: size,
        capture: { images[0] }, turn: {}, validate: {}, wait: { _ in throw CancellationError() })
    try require(!stopped.completed && stopped.saved == 1 && stopped.pdf != nil, "cancel must finalize saved pages")
    let before = try await engine.run(root: directory, pages: 3, interval: 1, pageSize: size,
        capture: { throw CancellationError() }, turn: {}, validate: {}, wait: noWait)
    try require(before.saved == 0 && before.pdf == nil, "cancel before first image must not publish empty PDF")
    print("PASS: cancellation before/after first saved page")

    captures = 0
    turns = 0
    let duplicate = try await engine.run(root: directory, pages: 3, interval: 1, pageSize: size,
        capture: { captures += 1; return images[0] }, turn: { turns += 1 }, validate: {}, wait: noWait)
    try require(!duplicate.completed && duplicate.saved == 1 && captures == 4 && turns == 1, "duplicate retries must not send more turns")
    print("PASS: duplicate-screen stop and retry bounds")

    let slowFrames = [images[0], images[0], images[1], images[2]]
    captures = 0
    turns = 0
    let slow = try await engine.run(root: directory, pages: 3, interval: 1, pageSize: size, capture: {
        defer { captures += 1 }; return slowFrames[captures]
    }, turn: { turns += 1 }, validate: {}, wait: noWait)
    try require(slow.completed && slow.saved == 3 && turns == 2, "slow page must recover without skipping a page")
    print("PASS: slow page rendering")

    var focusLost = false
    turns = 0
    let focus = try await engine.run(root: directory, pages: 3, interval: 1, pageSize: size, capture: { images[0] },
        turn: { turns += 1 }, validate: { if focusLost { throw CaptureError("focus lost") } }, wait: noWait,
        progress: { _ in focusLost = true })
    try require(focus.saved == 1 && turns == 0 && !focus.completed, "focus loss must stop before next input")
    print("PASS: focus-loss interlock")

    captures = 0
    let failure = try await engine.run(root: directory, pages: 3, interval: 1, pageSize: size, capture: {
        captures += 1
        if captures > 1 { throw CaptureError("screenshot failed") }
        return images[0]
    }, turn: {}, validate: {}, wait: noWait)
    try require(failure.saved == 1 && failure.pdf != nil && !failure.completed, "capture failure must keep partial PDF")
    print("PASS: partial export on capture failure")

    let imageDirectory = directory.appendingPathComponent("ordering-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
    for (file, image) in zip(["1.png", "2.png", "10.png"], images) {
        try pngData(image).write(to: imageDirectory.appendingPathComponent(file))
    }
    let files = try imageFiles(in: imageDirectory)
    try require(files.map(\.lastPathComponent) == ["1.png", "2.png", "10.png"], "natural filename ordering")
    let rebuilt = imageDirectory.appendingPathComponent("combined.pdf")
    try combineImages(files, into: rebuilt)
    try require(CGPDFDocument(rebuilt as CFURL)?.numberOfPages == 3, "rebuild PDF count")
    print("PASS: image-folder PDF rebuild")

    let local = CGRect(x: 10, y: 20, width: 300, height: 400)
    try require(CaptureRegion.topLeftRect(local, height: 900) == CGRect(x: 10, y: 480, width: 300, height: 400), "capture region origin")
    let point = CaptureRegion.quartzPoint(CGPoint(x: 100, y: 200), screenFrame: CGRect(x: -1600, y: -300, width: 1600, height: 900), primaryTop: 1000)
    try require(point == CGPoint(x: -1500, y: 1100), "secondary display click coordinates")
    print("PASS: display coordinate conversion")
    try original.write(to: directory.appendingPathComponent("preview.pdf"), options: .atomic)
    print("ALL TESTS PASSED\nVisual QA: \(directory.appendingPathComponent("preview.pdf").path)")
}
