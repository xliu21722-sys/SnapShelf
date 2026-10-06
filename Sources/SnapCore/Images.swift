import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

public enum ImageTools {
    public static let maxPixels = 32_000_000
    public static let maxDimension = 32_760

    public static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ShelfError.message("无法读取截图：\(url.lastPathComponent)")
        }
        return image
    }

    public static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ShelfError.message("无法创建 PNG 图片。")
        }
        CGImageDestinationAddImage(target, image, nil)
        guard CGImageDestinationFinalize(target) else { throw ShelfError.message("PNG 编码失败。") }
        return data as Data
    }

    public static func context(width: Int, height: Int) throws -> CGContext {
        guard width > 0, height > 0, width <= maxDimension, height <= maxDimension,
              width <= maxPixels / height else {
            throw ShelfError.message("长图已达到安全尺寸，请缩小导出宽度或分批导出。已有截图仍然保留。")
        }
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ShelfError.message("内存不足，无法生成长图。")
        }
        return context
    }

    public static func thumbnail(_ image: CGImage, maxWidth: Int = 600, maxHeight: Int = 400) -> NSImage {
        let scale = min(1, min(Double(maxWidth) / Double(image.width), Double(maxHeight) / Double(image.height)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let context = try? context(width: width, height: height) else { return NSImage() }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { return NSImage() }
        return NSImage(cgImage: result, size: NSSize(width: width, height: height))
    }

    public static func concatenate(_ strips: [CGImage]) throws -> CGImage {
        guard let first = strips.first else { throw ShelfError.message("还没有捕获内容。") }
        guard strips.allSatisfy({ $0.width == first.width }) else { throw ShelfError.message("截图宽度发生变化，请重新框选。") }
        let height = strips.reduce(0) { $0 + $1.height }
        let context = try context(width: first.width, height: height)
        var top = 0
        for strip in strips {
            context.draw(strip, in: CGRect(x: 0, y: height - top - strip.height, width: first.width, height: strip.height))
            top += strip.height
        }
        guard let output = context.makeImage() else { throw ShelfError.message("长图生成失败。") }
        return output
    }
}

public struct CompositionItem {
    public let image: CGImage
    public let note: String
    public init(image: CGImage, note: String) { self.image = image; self.note = note }
}

public enum LongImageComposer {
    public static func compose(_ items: [CompositionItem], maxWidth: Int = 1600) throws -> CGImage {
        guard !items.isEmpty else { throw ShelfError.message("请先截取至少一张图片。") }
        let width = min(max(64, maxWidth), items.map { $0.image.width }.max() ?? 1600)
        let padding = min(24, width / 8)
        let textWidth = width - padding * 2
        let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, 20, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.15, alpha: 1)
        ]
        struct Row { let item: CompositionItem; let imageHeight: Int; let imageWidth: Int; let text: NSAttributedString; let textHeight: Int }
        var rows: [Row] = []
        var totalHeight = 0
        for item in items {
            let scale = min(1, Double(width) / Double(item.image.width))
            let iw = max(1, Int(Double(item.image.width) * scale))
            let ih = max(1, Int(Double(item.image.height) * scale))
            let note = item.note.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = NSAttributedString(string: note, attributes: attrs)
            let setter = CTFramesetterCreateWithAttributedString(text)
            let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil,
                        CGSize(width: CGFloat(textWidth), height: CGFloat.greatestFiniteMagnitude), nil)
            let th = note.isEmpty ? 0 : Int(ceil(size.height)) + 8
            totalHeight += ih + (th > 0 ? padding + th : 0) + padding
            rows.append(Row(item: item, imageHeight: ih, imageWidth: iw, text: text, textHeight: th))
        }
        totalHeight -= padding
        let context = try ImageTools.context(width: width, height: totalHeight)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: totalHeight))
        context.interpolationQuality = .high
        var top = 0
        for row in rows {
            context.draw(row.item.image, in: CGRect(x: (width - row.imageWidth) / 2,
                         y: totalHeight - top - row.imageHeight, width: row.imageWidth, height: row.imageHeight))
            top += row.imageHeight
            if row.textHeight > 0 {
                top += padding
                let rect = CGRect(x: padding, y: totalHeight - top - row.textHeight, width: textWidth, height: row.textHeight)
                let setter = CTFramesetterCreateWithAttributedString(row.text)
                let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: rect, transform: nil), nil)
                context.textMatrix = .identity
                CTFrameDraw(frame, context)
                top += row.textHeight
            }
            top += padding
        }
        guard let result = context.makeImage() else { throw ShelfError.message("合成长图失败。") }
        return result
    }
}
