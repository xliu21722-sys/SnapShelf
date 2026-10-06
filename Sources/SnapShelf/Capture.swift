import AppKit
import ScreenCaptureKit
import SnapCore

struct CaptureRegion {
    let displayID: CGDirectDisplayID
    let screenFrame: CGRect
    let rect: CGRect // AppKit global coordinates, origin at bottom left.
    let scale: CGFloat
    var sourceRect: CGRect {
        CGRect(x: rect.minX - screenFrame.minX, y: screenFrame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}

@MainActor
final class ScreenCaptureService {
    private var filter: SCContentFilter?
    private var config: SCStreamConfiguration?

    func prepare(_ region: CaptureRegion) async throws {
        // Include hidden windows so our app can be excluded before the HUD opens.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
            throw ShelfError.message("所选显示器已断开，请重新框选。")
        }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        guard !ownApps.isEmpty else { throw ShelfError.message("无法排除工具自身窗口，请重新打开暂存栏后再试。") }
        filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = region.sourceRect
        configuration.width = max(1, Int((region.rect.width * region.scale).rounded()))
        configuration.height = max(1, Int((region.rect.height * region.scale).rounded()))
        configuration.showsCursor = false
        if #available(macOS 15, *) { configuration.showMouseClicks = false }
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.scalesToFit = true
        configuration.ignoreShadowsDisplay = true
        config = configuration
    }

    func capture() async throws -> CGImage {
        guard let filter, let config else { throw ShelfError.message("请先选择截图区域。") }
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SelectionController {
    private var panels: [NSPanel] = []
    private var completion: ((CaptureRegion?) -> Void)?

    func select(scrolling: Bool, completion: @escaping (CaptureRegion?) -> Void) {
        self.completion = completion
        NSApp.activate(ignoringOtherApps: true)
        for screen in NSScreen.screens {
            let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size), scrolling: scrolling)
            view.onSelection = { [weak self, weak screen] local in
                guard let self, let screen else { return }
                guard let local else { self.finish(nil); return }
                guard local.width >= 30, local.height >= (scrolling ? 100 : 20) else { NSSound.beep(); return }
                let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                let global = local.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
                self.finish(CaptureRegion(displayID: id, screenFrame: screen.frame, rect: global, scale: screen.backingScaleFactor))
            }
            panel.contentView = view
            panels.append(panel)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(view)
        }
        if let panel = panels.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) { panel.makeKey() }
        NSCursor.crosshair.push()
    }

    private func finish(_ region: CaptureRegion?) {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        NSCursor.pop()
        let callback = completion
        completion = nil
        callback?(region)
    }
}

final class SelectionView: NSView {
    let scrolling: Bool
    var onSelection: ((CGRect?) -> Void)?
    private var start: NSPoint?
    private var selected: CGRect?
    override var acceptsFirstResponder: Bool { true }
    init(frame: CGRect, scrolling: Bool) { self.scrolling = scrolling; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        start = convert(event.locationInWindow, from: nil)
        selected = nil
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let p = convert(event.locationInWindow, from: nil)
        selected = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y)).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { if let selected { onSelection?(selected.integral) } }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onSelection?(nil) }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()
        if let selected {
            NSColor.clear.setFill()
            selected.fill(using: .copy)
            NSColor.systemMint.setStroke()
            let border = NSBezierPath(rect: selected)
            border.lineWidth = 2
            border.stroke()
        }
        let text = scrolling ? "框选滚动内容 · 避开固定标题栏 · 松开后向下滚动 · Esc 取消" : "拖动框选截图 · 默认隐藏鼠标 · Esc 取消"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        let rect = CGRect(x: (bounds.width - size.width) / 2 - 20, y: bounds.height - 100, width: size.width + 40, height: 48)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
        (text as NSString).draw(at: NSPoint(x: rect.minX + 20, y: rect.minY + 13), withAttributes: attrs)
    }
}

struct SourceWindow: Equatable {
    let pid: pid_t
    let windowID: CGWindowID
    let bounds: CGRect
    let title: String

    static func current(pid: pid_t) -> SourceWindow? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let number = window[kCGWindowNumber as String] as? NSNumber,
                  let boundsInfo = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary) else { continue }
            return SourceWindow(pid: pid, windowID: number.uint32Value, bounds: bounds,
                                title: window[kCGWindowName as String] as? String ?? "")
        }
        return nil
    }
}
