import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let p = CGFloat(pixels)
        let background = NSBezierPath(roundedRect: NSRect(x: p * 0.08, y: p * 0.08, width: p * 0.84, height: p * 0.84), xRadius: p * 0.19, yRadius: p * 0.19)
        NSGradient(starting: NSColor(calibratedRed: 0.39, green: 0.42, blue: 0.92, alpha: 1), ending: NSColor(calibratedRed: 0.23, green: 0.25, blue: 0.66, alpha: 1))!.draw(in: background, angle: -70)
        for offset in [2, 1, 0] {
            let dy = CGFloat(offset) * p * 0.09
            NSColor.white.withAlphaComponent(offset == 0 ? 1 : 0.25).setFill()
            NSBezierPath(roundedRect: NSRect(x: p * 0.26, y: p * 0.39 - dy, width: p * 0.48, height: p * 0.32), xRadius: p * 0.045, yRadius: p * 0.045).fill()
        }
        NSColor(calibratedRed: 0.37, green: 0.4, blue: 0.86, alpha: 1).setStroke()
        let mark = NSBezierPath()
        mark.lineWidth = max(1, p * 0.028)
        mark.lineCapStyle = .round
        mark.move(to: NSPoint(x: p * 0.36, y: p * 0.49))
        mark.line(to: NSPoint(x: p * 0.47, y: p * 0.59))
        mark.line(to: NSPoint(x: p * 0.54, y: p * 0.52))
        mark.line(to: NSPoint(x: p * 0.64, y: p * 0.62))
        mark.stroke()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
