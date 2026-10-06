import Foundation
import CoreGraphics
import AppKit

public struct GrayFrame {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width > 0 && height > 0 && pixels.count == width * height)
        self.width = width; self.height = height; self.pixels = pixels
    }

    public init(image: CGImage, maxWidth: Int = 160, maxHeight: Int = 480) throws {
        let factor = min(1, min(Double(maxWidth) / Double(image.width), Double(maxHeight) / Double(image.height)))
        width = max(1, Int(Double(image.width) * factor))
        height = max(1, Int(Double(image.height) * factor))
        var buffer = [UInt8](repeating: 0, count: width * height)
        let w = width, h = height
        let ok = buffer.withUnsafeMutableBytes { pointer -> Bool in
            guard let c = CGContext(data: pointer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                    bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            c.interpolationQuality = .low
            c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw ShelfError.message("无法分析滚动截图。") }
        pixels = buffer
    }

    public func difference(_ other: GrayFrame) -> Double {
        guard width == other.width, height == other.height else { return .infinity }
        var sum = 0
        for i in pixels.indices { sum += abs(Int(pixels[i]) - Int(other.pixels[i])) }
        return Double(sum) / Double(pixels.count)
    }
}

public enum MatchResult: Equatable {
    case duplicate
    case append(Int)
    case uncertain
    case reverse
}

/// A conservative vertical matcher: require a textured, unambiguous overlap.
/// Positive shifts mean that content moved up as the user scrolled down.
public enum ScrollMatcher {
    private static func error(previous: GrayFrame, current: GrayFrame, shift: Int) -> (Double, Double) {
        let start = max(0, -shift), end = min(current.height, previous.height - shift)
        let inset = max(2, current.width / 20)
        var sum = 0, texture = 0, count = 0
        for y in stride(from: start, to: end - 1, by: 3) {
            for x in stride(from: inset, to: current.width - inset, by: 2) {
                let a = Int(previous.pixels[(y + shift) * previous.width + x])
                let b = Int(current.pixels[y * current.width + x])
                sum += abs(a - b)
                texture += abs(b - Int(current.pixels[(y + 1) * current.width + x]))
                count += 1
            }
        }
        return (Double(sum) / Double(max(1, count)), Double(texture) / Double(max(1, count)))
    }

    /// Coarse sampling can alias small text. Use several candidate peaks, then
    /// compare every source row at full vertical resolution before choosing one.
    public static func matchImages(previous: CGImage, current: CGImage,
                                   previousGray: GrayFrame, currentGray: GrayFrame) throws -> MatchResult {
        guard previous.width == current.width, previous.height == current.height,
              previousGray.width == currentGray.width, previousGray.height == currentGray.height else { return .uncertain }
        if previousGray.difference(currentGray) < 0.8 { return .duplicate }
        let limit = Int(Double(previousGray.height) * 0.65)
        guard previousGray.width >= 16, limit > 0 else { return .uncertain }
        var coarse: [(Int, Double)] = []
        for shift in -limit...limit where shift != 0 {
            coarse.append((shift, error(previous: previousGray, current: currentGray, shift: shift).0))
        }
        coarse.sort { $0.1 < $1.1 }
        var peaks: [Int] = []
        for (shift, score) in coarse where score < 18 {
            if peaks.allSatisfy({ abs($0 - shift) > 2 }) { peaks.append(shift) }
            if peaks.count == 8 { break }
        }
        guard !peaks.isEmpty else { return .uncertain }
        let a = try rowSignature(previous), b = try rowSignature(current)
        let scale = Double(previous.height) / Double(previousGray.height)
        let radius = Int(ceil(scale * 2))
        var offsets = Set<Int>()
        for peak in peaks {
            let estimate = Int((Double(peak) * scale).rounded())
            for shift in (estimate - radius)...(estimate + radius)
                where shift != 0 && abs(shift) <= Int(Double(previous.height) * 0.65) {
                offsets.insert(shift)
            }
        }
        let refined = offsets.map { shift -> (Int, Double, Double) in
            let score = error(previous: a, current: b, shift: shift)
            return (shift, score.0, score.1)
        }.sorted { $0.1 < $1.1 }
        guard let best = refined.first, best.1 < 3, best.2 > 0.3 else { return .uncertain }
        if let runner = refined.first(where: { abs($0.0 - best.0) > 2 }), runner.1 < best.1 * 1.4 + 0.2 {
            return .uncertain
        }
        return best.0 < 0 ? .reverse : .append(best.0)
    }

    private static func rowSignature(_ image: CGImage) throws -> GrayFrame {
        let w = min(128, image.width), h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h)
        let ok = pixels.withUnsafeMutableBytes { data -> Bool in
            guard let c = CGContext(data: data.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                    bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            c.interpolationQuality = .low
            c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw ShelfError.message("无法计算拼接位置。") }
        return GrayFrame(width: w, height: h, pixels: pixels)
    }
}

public final class ScrollStitcher {
    public private(set) var strips: [CGImage] = []
    public private(set) var totalHeight = 0
    public private(set) var previous: CGImage?
    private var previousGray: GrayFrame?

    public init() {}

    @discardableResult
    public func consume(_ image: CGImage) throws -> MatchResult {
        let gray = try GrayFrame(image: image)
        guard let previous, let previousGray else {
            try checkLimit(width: image.width, height: image.height)
            strips = [image]; totalHeight = image.height
            self.previous = image; self.previousGray = gray
            return .append(image.height)
        }
        guard previous.width == image.width, previous.height == image.height else { return .uncertain }
        let match = try ScrollMatcher.matchImages(previous: previous, current: image, previousGray: previousGray, currentGray: gray)
        guard case .append(let shift) = match else { return match }
        try checkLimit(width: image.width, height: totalHeight + shift)
        guard let crop = image.cropping(to: CGRect(x: 0, y: image.height - shift, width: image.width, height: shift)) else {
            throw ShelfError.message("无法提取新滚动内容。")
        }
        // Copy the strip: a CGImage crop may otherwise retain the entire source frame.
        let context = try ImageTools.context(width: crop.width, height: crop.height)
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        guard let strip = context.makeImage() else { throw ShelfError.message("无法保存新增内容。") }
        strips.append(strip); totalHeight += shift
        self.previous = image; self.previousGray = gray
        return .append(shift)
    }

    private func checkLimit(width: Int, height: Int) throws {
        guard width <= ImageTools.maxDimension, height <= ImageTools.maxDimension, width <= ImageTools.maxPixels / height else {
            throw ShelfError.message("已达到长图安全上限，请点击完成保存已有内容。")
        }
    }

    public func finish() throws -> CGImage { try ImageTools.concatenate(strips) }

    public func preview() -> NSImage? {
        guard let first = strips.first else { return nil }
        let width = 180
        let factor = Double(width) / Double(first.width)
        let height = max(1, min(2400, Int(Double(totalHeight) * factor)))
        guard let c = try? ImageTools.context(width: width, height: height) else { return nil }
        let actualScale = min(factor, Double(height) / Double(totalHeight))
        var top: Double = 0
        for strip in strips {
            let sh = Double(strip.height) * actualScale, sw = Double(strip.width) * actualScale
            c.draw(strip, in: CGRect(x: (Double(width) - sw) / 2, y: Double(height) - top - sh, width: sw, height: sh))
            top += sh
        }
        guard let cg = c.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }
}
