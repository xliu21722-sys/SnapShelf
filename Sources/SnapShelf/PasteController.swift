import AppKit
import ApplicationServices
import SnapCore

@MainActor
final class PasteController: ObservableObject {
    @Published var running = false
    @Published var status = ""
    @Published var interval: Double = UserDefaults.standard.object(forKey: "pasteInterval") as? Double ?? 1.8 {
        didSet { UserDefaults.standard.set(interval, forKey: "pasteInterval") }
    }
    private var task: Task<Void, Never>?
    private var targetWindow: AXUIElement?
    private var targetPID: pid_t?
    private var focus: AXUIElement?
    private var guardedWindow: AXUIElement?
    private var expectedClipboard: Int?
    private var inputMonitor: Any?
    private static let eventTag: Int64 = 0x534E41505348454C
    var onFinish: (() -> Void)?

    static func trusted(prompt: Bool = false) -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary)
    }

    func rememberChrome() {
        guard Self.trusted(), let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first else { return }
        let app = AXUIElementCreateApplication(chrome.processIdentifier)
        if let window = element(app, kAXFocusedWindowAttribute) {
            targetWindow = window
            targetPID = chrome.processIdentifier
        }
    }

    func start(clips: [Clip], directory: URL) {
        guard !running, !clips.isEmpty else { return }
        guard Self.trusted(prompt: true) else {
            status = "请在系统设置中允许「截图暂存」使用辅助功能，然后重新点击粘贴。"
            return
        }
        guard let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first else {
            status = "请先打开 Chrome 的飞书文档并点击插入位置。"
            return
        }
        // Resolve and validate every image before changing the target document.
        for clip in clips {
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(clip.filename).path) else {
                status = "有截图文件缺失，请先恢复或删除对应条目。"; return
            }
        }
        running = true
        expectedClipboard = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if let monitor = self.inputMonitor { NSEvent.removeMonitor(monitor) }
                self.inputMonitor = nil
                self.running = false; self.expectedClipboard = nil; self.onFinish?()
            }
            do {
                let app = AXUIElementCreateApplication(chrome.processIdentifier)
                if self.targetPID == chrome.processIdentifier, let window = self.targetWindow {
                    guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else {
                        throw ShelfError.message("原 Chrome 窗口已失效，请重新在文档中点击插入位置。")
                    }
                }
                chrome.activate()
                try await Task.sleep(nanoseconds: 500_000_000)
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == chrome.processIdentifier,
                      let window = self.element(app, kAXFocusedWindowAttribute),
                      let focus = self.element(app, kAXFocusedUIElementAttribute) else {
                    throw ShelfError.message("无法确认 Chrome 输入位置，请在文档正文中点击后重试。")
                }
                guard self.isEditable(focus) else {
                    throw ShelfError.message("当前焦点不是可编辑正文，请先点击飞书文档的输入位置。")
                }
                self.guardedWindow = window
                self.focus = focus
                self.inputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
                    // Stop if the user edits or moves the caret, even if the AX
                    // editor element stays the same. Ignore only our own events.
                    guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Self.eventTag else { return }
                    Task { @MainActor in self?.cancel() }
                }
                for remaining in (1...3).reversed() {
                    self.status = "\(remaining) 秒后开始粘贴 · Esc 取消"
                    try await self.wait(1, pid: chrome.processIdentifier)
                }
                for (i, clip) in clips.enumerated() {
                    try self.checkTarget(pid: chrome.processIdentifier)
                    self.status = "正在发送第 \(i + 1) / \(clips.count) 张 · Esc 取消"
                    let cg = try ImageTools.load(directory.appendingPathComponent(clip.filename))
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    guard pasteboard.writeObjects([NSImage(cgImage: cg, size: .zero)]) else {
                        throw ShelfError.message("无法写入剪贴板。")
                    }
                    self.expectedClipboard = pasteboard.changeCount
                    try self.press(9, flags: .maskCommand) // Command-V
                    try await self.wait(self.interval, pid: chrome.processIdentifier)
                    try self.press(124, flags: []) // Leave an inserted/selected image.
                    try self.press(36, flags: [])
                    try await self.wait(0.2, pid: chrome.processIdentifier)
                    if !clip.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        try self.checkTarget(pid: chrome.processIdentifier)
                        pasteboard.clearContents()
                        guard pasteboard.setString(clip.note, forType: .string) else { throw ShelfError.message("无法复制备注。") }
                        self.expectedClipboard = pasteboard.changeCount
                        try self.press(9, flags: .maskCommand)
                        try await self.wait(max(0.4, self.interval / 2), pid: chrome.processIdentifier)
                        try self.press(36, flags: [])
                        try await self.wait(0.2, pid: chrome.processIdentifier)
                    }
                }
                self.status = "已发送 \(clips.count) 张图片的粘贴操作，请在飞书检查图片、备注和保存状态。"
            } catch is CancellationError {
                self.status = "已停止后续粘贴，已插入的内容保留；重试前请检查文档，避免重复。"
            } catch {
                self.status = error.localizedDescription + " 后续输入已停止，请检查已插入的内容。"
            }
        }
    }

    func cancel() { task?.cancel() }

    private func wait(_ seconds: Double, pid: pid_t) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try Task.checkCancellation()
            try checkTarget(pid: pid)
            try await Task.sleep(nanoseconds: 80_000_000)
        }
    }

    private func checkTarget(pid: pid_t) throws {
        try Task.checkCancellation()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            throw ShelfError.message("目标应用发生变化。")
        }
        let app = AXUIElementCreateApplication(pid)
        guard let currentWindow = element(app, kAXFocusedWindowAttribute), let guardedWindow,
              CFEqual(currentWindow, guardedWindow),
              let currentFocus = element(app, kAXFocusedUIElementAttribute), let focus,
              CFEqual(currentFocus, focus) else {
            throw ShelfError.message("目标窗口或输入焦点发生变化。")
        }
        if let expectedClipboard, NSPasteboard.general.changeCount != expectedClipboard {
            throw ShelfError.message("剪贴板被其他操作修改。")
        }
    }

    private func press(_ key: CGKeyCode, flags: CGEventFlags) throws {
        try Task.checkCancellation()
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
            throw ShelfError.message("无法发送粘贴按键。")
        }
        down.flags = flags; up.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        up.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }

    private func isEditable(_ value: AXUIElement) -> Bool {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(value, kAXRoleAttribute as CFString, &role)
        let name = role as? String ?? ""
        // Never paste into Chrome's address/search field. Web contenteditable is
        // normally exposed as AXTextArea; reject unknown roles conservatively.
        return name == kAXTextAreaRole
    }

    private func element(_ value: AXUIElement, _ attribute: String) -> AXUIElement? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(value, attribute as CFString, &result) == .success,
              let result, CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }
}
