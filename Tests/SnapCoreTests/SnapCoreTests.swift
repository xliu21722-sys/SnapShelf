import AppKit
import CoreText
import SnapCore

final class SnapCoreTests: CheckSuite {
    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SnapShelfTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func noiseImage(width: Int = 160, height: Int = 1200) -> CGImage {
        var state: UInt64 = 12345678
        var pixels = [UInt8](repeating: 0, count: width * height)
        for index in pixels.indices {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            pixels[index] = UInt8((state >> 33) & 255)
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func page(_ image: CGImage, from y: Int, height: Int = 300) -> CGImage {
        image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: height))!
    }

    private func match(previous: GrayFrame, current: GrayFrame) throws -> MatchResult {
        func image(_ frame: GrayFrame) -> CGImage {
            CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: frame.width,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                    provider: CGDataProvider(data: Data(frame.pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
        let stitcher = ScrollStitcher()
        try stitcher.consume(image(previous))
        return try stitcher.consume(image(current))
    }

    func testPersistenceNotesAndOrder() throws {
        let directory = try tempDirectory()
        let repository = try LibraryRepository(directory: directory)
        let image = noiseImage(height: 40)
        let first = try repository.add(image)
        let second = try repository.add(image, note: "第二题")
        try repository.updateNote(id: first.id, note: "中文备注\n第二行")
        try repository.move(id: second.id, to: 0)
        let reopened = try LibraryRepository(directory: directory)
        XCTAssertEqual(reopened.state.clips.map(\.id), [second.id, first.id])
        XCTAssertEqual(reopened.state.clips[1].note, "中文备注\n第二行")
        XCTAssertEqual(try ImageTools.load(reopened.imageURL(first)).width, 160)
    }

    func testDeleteUndoSurvivesRestart() throws {
        let directory = try tempDirectory()
        let repository = try LibraryRepository(directory: directory)
        let first = try repository.add(noiseImage(height: 20))
        let second = try repository.add(noiseImage(height: 20))
        try repository.remove(id: first.id)
        XCTAssertEqual(repository.state.clips.map(\.id), [second.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.imageURL(first).path))
        let reopened = try LibraryRepository(directory: directory)
        try reopened.undoRemove()
        XCTAssertEqual(reopened.state.clips.map(\.id), [first.id, second.id])
        XCTAssertNil(reopened.state.deleted)
    }

    func testMoveClampsAndUnknownIDsAreNoOps() throws {
        let repository = try LibraryRepository(directory: tempDirectory())
        let a = try repository.add(noiseImage(height: 20))
        let b = try repository.add(noiseImage(height: 20))
        try repository.move(id: a.id, to: 999)
        XCTAssertEqual(repository.state.clips.map(\.id), [b.id, a.id])
        try repository.move(id: a.id, to: -10)
        try repository.remove(id: UUID())
        XCTAssertEqual(repository.state.clips.map(\.id), [a.id, b.id])
    }

    func testMalformedManifestIsNotOverwritten() throws {
        let directory = try tempDirectory()
        let manifest = directory.appendingPathComponent("library.json")
        let original = Data("not valid json".utf8)
        try original.write(to: manifest)
        XCTAssertThrowsError(try LibraryRepository(directory: directory))
        XCTAssertEqual(try Data(contentsOf: manifest), original)
    }

    func testRejectsUnsafeFilename() throws {
        let directory = try tempDirectory()
        let repository = try LibraryRepository(directory: directory)
        _ = try repository.add(noiseImage(height: 20))
        let manifest = directory.appendingPathComponent("library.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        var clips = json["clips"] as! [[String: Any]]
        clips[0]["filename"] = "../../other.png"
        json["clips"] = clips
        try JSONSerialization.data(withJSONObject: json).write(to: manifest)
        XCTAssertThrowsError(try LibraryRepository(directory: directory))
    }

    func testDetectsExactScrollAndDuplicate() throws {
        let image = noiseImage()
        let a = try GrayFrame(image: page(image, from: 0))
        let b = try GrayFrame(image: page(image, from: 93))
        XCTAssertEqual(try match(previous: a, current: b), .append(93))
        XCTAssertEqual(try match(previous: a, current: a), .duplicate)
        XCTAssertEqual(try match(previous: b, current: a), .reverse)
    }

    func testRejectsFastScrollWithoutOverlap() throws {
        let image = noiseImage()
        let a = try GrayFrame(image: page(image, from: 0))
        let b = try GrayFrame(image: page(image, from: 350))
        XCTAssertEqual(try match(previous: a, current: b), .uncertain)
    }

    func testRejectsAmbiguousRepeatedRows() {
        let w = 100, h = 300
        let pixels = (0..<(w * h)).map { i in UInt8(((i / w) % 20) * 10) }
        let shifted = (0..<(w * h)).map { i in UInt8((((i / w) + 7) % 20) * 10) }
        XCTAssertEqual(try match(previous: GrayFrame(width: w, height: h, pixels: pixels),
                                          current: GrayFrame(width: w, height: h, pixels: shifted)), .uncertain)
    }

    func testBlankPagesAreNotInventedAsScroll() {
        let a = GrayFrame(width: 80, height: 100, pixels: Array(repeating: 255, count: 8000))
        let b = GrayFrame(width: 80, height: 100, pixels: Array(repeating: 245, count: 8000))
        XCTAssertEqual(try match(previous: a, current: a), .duplicate)
        XCTAssertEqual(try match(previous: a, current: b), .uncertain)
    }

    func testScrollStitchHasExactPixelsAndNoRepeatedRows() throws {
        let document = noiseImage()
        let stitcher = ScrollStitcher()
        XCTAssertEqual(try stitcher.consume(page(document, from: 0)), .append(300))
        XCTAssertEqual(try stitcher.consume(page(document, from: 91)), .append(91))
        XCTAssertEqual(try stitcher.consume(page(document, from: 91)), .duplicate)
        XCTAssertEqual(try stitcher.consume(page(document, from: 207)), .append(116))
        let result = try stitcher.finish()
        XCTAssertEqual(result.height, 507)
        let expected = try GrayFrame(image: page(document, from: 0, height: 507), maxWidth: 160, maxHeight: 507)
        let actual = try GrayFrame(image: result, maxWidth: 160, maxHeight: 507)
        XCTAssertLessThan(actual.difference(expected), 0.01)
    }

    func testUncertainFrameKeepsAcceptedReferenceForRecovery() throws {
        let document = noiseImage()
        let stitcher = ScrollStitcher()
        try stitcher.consume(page(document, from: 0))
        XCTAssertEqual(try stitcher.consume(page(document, from: 400)), .uncertain)
        XCTAssertEqual(stitcher.totalHeight, 300)
        XCTAssertEqual(try stitcher.consume(page(document, from: 90)), .append(90))
        XCTAssertEqual(stitcher.totalHeight, 390)
    }

    func testMixedWidthsNotesAndNoUpscaling() throws {
        let small = noiseImage(width: 80, height: 60)
        let output = try LongImageComposer.compose([CompositionItem(image: small, note: "")], maxWidth: 1600)
        XCTAssertEqual(output.width, 80)
        XCTAssertEqual(output.height, 60)
        let mixed = try LongImageComposer.compose([
            CompositionItem(image: small, note: String(repeating: "中文备注需要完整换行。", count: 30)),
            CompositionItem(image: noiseImage(width: 400, height: 160), note: "第二张")
        ], maxWidth: 200)
        XCTAssertEqual(mixed.width, 200)
        XCTAssertGreaterThan(mixed.height, 300)
    }

    func testPixelAndDimensionLimits() {
        XCTAssertThrowsError(try ImageTools.context(width: 1600, height: 30000))
        XCTAssertThrowsError(try ImageTools.context(width: 100, height: 40000))
        XCTAssertThrowsError(try ImageTools.context(width: 0, height: 10))
        XCTAssertThrowsError(try LongImageComposer.compose([]))
    }

    func testPNGIsLosslessAndPreservesResolution() throws {
        let image = noiseImage(width: 640, height: 420)
        let url = try tempDirectory().appendingPathComponent("retina.png")
        try ImageTools.png(image).write(to: url)
        let decoded = try ImageTools.load(url)
        XCTAssertEqual(decoded.width, 640)
        XCTAssertEqual(decoded.height, 420)
        XCTAssertEqual(try GrayFrame(image: image).difference(GrayFrame(image: decoded)), 0)
    }

    func testRetinaTextPageSubpixelCoarseShiftAndExportArtifacts() throws {
        let width = 960, height = 3200
        let context = try ImageTools.context(width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, 26, nil)
        for i in 0..<40 {
            let y = height - (i + 1) * 80
            context.setFillColor(CGColor(gray: i % 2 == 0 ? 0.96 : 1, alpha: 1))
            context.fill(CGRect(x: 0, y: y, width: width, height: 80))
            let text = NSAttributedString(string: String(format: "%03d", i + 1) + "  复习第 \(i + 1) 题：已知 x² + \(i * 13 + 7)x = \(i * i + 23)，求解。",
               attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.15, alpha: 1)])
            context.textPosition = CGPoint(x: 28, y: y + 36)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.setFillColor(CGColor(red: CGFloat((i * 37) % 100) / 130, green: 0.4, blue: 0.75, alpha: 1))
            context.fill(CGRect(x: 28, y: y + 12, width: 60 + (i * 73) % 530, height: 8))
        }
        let document = try XCTUnwrap(context.makeImage())
        let stitcher = ScrollStitcher()
        try stitcher.consume(page(document, from: 0, height: 960))
        for offset in [173, 407, 690, 977, 1263] {
            guard case .append = try stitcher.consume(page(document, from: offset, height: 960)) else {
                throw NSError(domain: "Checks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Retina text match failed at offset \(offset)"])
            }
        }
        let result = try stitcher.finish()
        XCTAssertEqual(result.height, 2223)
        let expected = try GrayFrame(image: page(document, from: 0, height: 2223), maxWidth: 960, maxHeight: 2223)
        let actual = try GrayFrame(image: result, maxWidth: 960, maxHeight: 2223)
        XCTAssertLessThan(actual.difference(expected), 0.02)
        let artifacts = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/check-artifacts")
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        try ImageTools.png(result).write(to: artifacts.appendingPathComponent("scroll-result.png"))
        let composed = try LongImageComposer.compose([
            CompositionItem(image: page(document, from: 0, height: 260), note: "第一题：注意定义域，先整理条件，再求解。\n这一行用于验证中文多行备注。"),
            CompositionItem(image: page(document, from: 320, height: 200), note: "第二题：检查代入后的结果。")
        ])
        try ImageTools.png(composed).write(to: artifacts.appendingPathComponent("notes-result.png"))
    }
}
