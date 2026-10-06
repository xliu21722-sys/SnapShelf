import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: AppModel!
    private var shelf: NSPanel!
    private var hud: NSPanel?
    private var pasteHUD: NSPanel?
    private var statusItem: NSStatusItem!
    private var previews: [NSWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model = AppModel()
        shelf = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 740),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        shelf.title = "截图暂存"
        shelf.titlebarAppearsTransparent = true
        shelf.titleVisibility = .hidden
        shelf.isReleasedWhenClosed = false
        shelf.level = .floating
        shelf.minSize = NSSize(width: 450, height: 620)
        shelf.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        shelf.contentView = NSHostingView(rootView: ShelfView(model: model, paste: model.paste).padding(.top, 20))
        shelf.setFrameAutosaveName("SnapShelfMain")
        if shelf.frame.origin == .zero { shelf.center() }
        model.hideShelf = { [weak self] in self?.shelf.orderOut(nil) }
        model.showShelf = { [weak self] in self?.showShelf() }
        model.showScrollHUD = { [weak self] region in self?.showHUD(region) }
        model.hideScrollHUD = { [weak self] in self?.hud?.orderOut(nil); self?.hud = nil }
        model.showPasteHUD = { [weak self] in self?.showPasteProgress() }
        model.showImage = { [weak self] image, title in self?.preview(image, title: title) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "截图暂存")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        createAppMenu()
        showShelf()
    }

    private func createAppMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于截图暂存", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出截图暂存", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "打开暂存栏", action: #selector(showShelf), keyEquivalent: "")
            menu.addItem(withTitle: "框选截图", action: #selector(capture), keyEquivalent: "")
            menu.addItem(withTitle: "滚动长截图", action: #selector(scrollCapture), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            for item in menu.items { item.target = item.title == "退出" ? NSApp : self }
            if let button = statusItem.button { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button) }
        } else { showShelf() }
    }

    @objc func showShelf() {
        model.screenAllowed = CGPreflightScreenCaptureAccess()
        NSApp.activate(ignoringOtherApps: true)
        shelf.makeKeyAndOrderFront(nil)
    }
    @objc private func capture() { model.startCapture(scrolling: false) }
    @objc private func scrollCapture() { model.startCapture(scrolling: true) }
    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "截图暂存", .applicationVersion: "0.1.0", .credits: NSAttributedString(string: "连续截图 · 滚动长图 · 有序整理\n本机保存，不含系统鼠标指针。")])
    }

    private func showHUD(_ region: CaptureRegion) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 262, height: 340),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ScrollHUDView(model: model))
        let screen = region.screenFrame.insetBy(dx: 16, dy: 40)
        var x = region.rect.maxX + 16
        if x + 262 > screen.maxX { x = region.rect.minX - 278 }
        if x < screen.minX { x = screen.maxX - 262 }
        let y = min(max(region.rect.maxY - 340, screen.minY), screen.maxY - 340)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
        hud = panel
    }

    private func preview(_ image: CGImage, title: String) {
        previews.removeAll { !$0.isVisible }
        shelf.orderOut(nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ImagePreviewView(image: image))
        window.center()
        previews.append(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              previews.contains(where: { $0 === window }) else { return }
        previews.removeAll { $0 === window }
        if previews.isEmpty { showShelf() }
    }

    private func showPasteProgress() {
        pasteHUD?.orderOut(nil)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 332, height: 170),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: PasteHUDView(paste: model.paste) { [weak self] in
            self?.pasteHUD?.orderOut(nil); self?.pasteHUD = nil
        })
        if let frame = NSScreen.main?.visibleFrame { panel.setFrameOrigin(NSPoint(x: frame.maxX - 352, y: frame.maxY - 200)) }
        panel.orderFrontRegardless()
        pasteHUD = panel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
