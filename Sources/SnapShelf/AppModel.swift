import AppKit
import SwiftUI
import SnapCore

@MainActor
final class AppModel: ObservableObject {
    @Published var clips: [Clip] = []
    @Published var thumbnails: [UUID: NSImage] = [:]
    @Published var message = ""
    @Published var errorMessage: String?
    @Published var canUndo = false
    @Published var capturing = false
    @Published var scrolling = false
    @Published var scrollPaused = false
    @Published var scrollStatus = ""
    @Published var scrollHeight = 0
    @Published var scrollPreview: NSImage?
    @Published var screenshotKey = UserDefaults.standard.string(forKey: "screenshotKey") ?? "S"
    @Published var scrollKey = UserDefaults.standard.string(forKey: "scrollKey") ?? "L"
    @Published var showSettings = false
    @Published var exportWidth = 1600
    @Published var screenAllowed = CGPreflightScreenCaptureAccess()
    let paste = PasteController()
    let hotKeys = HotKeys()
    private var repository: LibraryRepository?
    private let captureService = ScreenCaptureService()
    private let selector = SelectionController()
    private var captureTask: Task<Void, Never>?
    private var stitcher: ScrollStitcher?
    private var activeRegion: CaptureRegion?
    private var sourceWindow: SourceWindow?
    private var sourceApp: NSRunningApplication?
    private var session = UUID()
    private var lastExternalApp: NSRunningApplication?
    private var observers: [NSObjectProtocol] = []
    private var inputMonitors: [Any] = []
    var hideShelf: (() -> Void)?
    var showShelf: (() -> Void)?
    var showScrollHUD: ((CaptureRegion) -> Void)?
    var hideScrollHUD: (() -> Void)?
    var showPasteHUD: (() -> Void)?
    var showImage: ((CGImage, String) -> Void)?

    var busy: Bool { capturing || scrolling || paste.running }
    var totalCount: Int { clips.count }

    init() {
        do {
            let arguments = ProcessInfo.processInfo.arguments
            let base: URL
            if let index = arguments.firstIndex(of: "--data-directory"), arguments.indices.contains(index + 1) {
                base = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
                message = "独立测试数据目录 · 不影响正式暂存内容"
            } else {
                base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("SnapShelf", isDirectory: true)
            }
            repository = try LibraryRepository(directory: base)
            reload()
        } catch {
            errorMessage = "无法打开暂存库：\(error.localizedDescription) 原数据已保留，截图功能暂不可用。"
        }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalApp = front
        }
        hotKeys.onKey = { [weak self] id in
            guard let self else { return }
            switch id {
            case 1: self.startCapture(scrolling: false)
            case 2: self.startCapture(scrolling: true)
            case 99:
                if self.scrolling { self.cancelScroll() }
                else if self.paste.running { self.paste.cancel() }
            default: break
            }
        }
        registerShortcuts()
        paste.onFinish = { [weak self] in self?.hotKeys.enableEscape(false) }
        let activated = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in
                guard let self, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self.lastExternalApp = app
                if self.scrolling, app.processIdentifier != self.sourceApp?.processIdentifier {
                    self.pauseScroll("已切换应用。回到原窗口后点击继续，或完成已有长图。")
                }
            }
        }
        observers.append(activated)
        let deactivated = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification,
                object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.google.Chrome" else { return }
            Task { @MainActor in self?.paste.rememberChrome() }
        }
        observers.append(deactivated)
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pauseScroll("显示器配置已变化，请完成已有长图后重新框选。") }
        })
        // Zoom keys are an additional pause signal when macOS allows monitoring.
        // Even without accessibility permission, image matching rejects scale changes.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.modifierFlags.contains(.command), [24, 27, 29].contains(Int(event.keyCode)) else { return }
            Task { @MainActor in self?.pauseScroll("检测到页面缩放操作，请恢复原缩放后继续，或完成已有长图。") }
        }) { inputMonitors.append(monitor) }
    }

    func registerShortcuts() {
        do { try hotKeys.set(id: 1, letter: screenshotKey) }
        catch { errorMessage = error.localizedDescription }
        do { try hotKeys.set(id: 2, letter: scrollKey) }
        catch { errorMessage = error.localizedDescription }
    }

    func changeShortcut(scrolling: Bool, letter: String) {
        let old = scrolling ? scrollKey : screenshotKey
        guard letter != old else { return }
        guard letter != (scrolling ? screenshotKey : scrollKey) else {
            errorMessage = "普通截图和滚动长截图需要使用不同字母。"; return
        }
        do {
            try hotKeys.set(id: scrolling ? 2 : 1, letter: letter)
            if scrolling { scrollKey = letter; UserDefaults.standard.set(letter, forKey: "scrollKey") }
            else { screenshotKey = letter; UserDefaults.standard.set(letter, forKey: "screenshotKey") }
            message = "快捷键已更新"
        } catch { errorMessage = error.localizedDescription }
    }

    func requestScreenPermission() {
        screenAllowed = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        if !screenAllowed {
            message = "请允许「截图暂存」录制屏幕；授权后若仍无法截图，请退出并重新打开应用。"
            openSettings("Privacy_ScreenCapture")
        }
    }

    func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }

    func startCapture(scrolling wantsScroll: Bool) {
        guard !busy, repository != nil else { return }
        screenAllowed = CGPreflightScreenCaptureAccess()
        guard screenAllowed else { requestScreenPermission(); return }
        capturing = true
        errorMessage = nil
        sourceApp = lastExternalApp
        hideShelf?()
        sourceApp?.activate()
        let token = UUID(); session = token
        Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard self.session == token else { return }
            self.selector.select(scrolling: wantsScroll) { [weak self] region in
                guard let self else { return }
                self.sourceApp?.activate()
                guard let region else { self.capturing = false; self.message = "已取消截图"; return }
                self.captureTask = Task { await self.begin(region: region, scrolling: wantsScroll, token: token) }
            }
        }
    }

    private func begin(region: CaptureRegion, scrolling wantsScroll: Bool, token: UUID) async {
        do {
            try await Task.sleep(nanoseconds: 200_000_000)
            try await captureService.prepare(region)
            try Task.checkCancellation()
            guard session == token else { return }
            let image = try await captureService.capture()
            guard session == token else { return }
            if !wantsScroll {
                try repository?.add(image)
                reload()
                message = "第 \(clips.count) 张已暂存 · 继续按 ⌥ \(screenshotKey) 截图"
                capturing = false
                return
            }
            guard let sourceApp, let window = SourceWindow.current(pid: sourceApp.processIdentifier) else {
                throw ShelfError.message("无法确认滚动来源窗口，请先点击要截图的页面再试。")
            }
            sourceWindow = window
            activeRegion = region
            let engine = ScrollStitcher()
            try engine.consume(image)
            stitcher = engine
            capturing = false; scrolling = true; scrollPaused = false
            scrollStatus = "缓慢向下滚动，停一下让画面稳定"
            updateScrollPreview()
            hotKeys.enableEscape(true)
            showScrollHUD?(region)
            await sampleLoop(token: token)
        } catch is CancellationError {
            capturing = false
        } catch {
            capturing = false
            errorMessage = "截图失败：\(error.localizedDescription)"
            showShelf?()
        }
    }

    private func sampleLoop(token: UUID) async {
        var candidate: GrayFrame?
        while !Task.isCancelled, session == token, scrolling {
            do {
                try await Task.sleep(nanoseconds: 280_000_000)
                guard session == token else { return }
                guard !scrollPaused else { candidate = nil; continue }
                guard let sourceApp, NSWorkspace.shared.frontmostApplication?.processIdentifier == sourceApp.processIdentifier,
                      let current = SourceWindow.current(pid: sourceApp.processIdentifier), current == sourceWindow else {
                    pauseScroll("来源窗口、标签页或窗口大小发生变化。恢复原窗口后点击继续。")
                    continue
                }
                let image = try await captureService.capture()
                guard session == token, scrolling else { return }
                if scrollPaused { candidate = nil; continue }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == sourceApp.processIdentifier,
                      SourceWindow.current(pid: sourceApp.processIdentifier) == sourceWindow else {
                    pauseScroll("捕获期间来源窗口发生变化，已停止追加。")
                    candidate = nil
                    continue
                }
                let gray = try GrayFrame(image: image)
                defer { candidate = gray }
                guard let old = candidate, old.difference(gray) < 0.8 else { continue }
                guard let engine = stitcher else { return }
                let result = try engine.consume(image)
                switch result {
                case .duplicate: break
                case .append:
                    scrollStatus = "已接上新内容 · 可继续向下滚动"
                    updateScrollPreview()
                case .reverse:
                    pauseScroll("检测到向上滚动。请回到预览末尾所在位置，再点击继续。")
                case .uncertain:
                    pauseScroll("暂时无法可靠拼接。请向上返回一点，保留至少半屏重叠后继续。")
                }
            } catch is CancellationError { return }
            catch { pauseScroll(error.localizedDescription) }
        }
    }

    private func updateScrollPreview() {
        scrollHeight = stitcher?.totalHeight ?? 0
        scrollPreview = stitcher?.preview()
    }

    func pauseScroll(_ reason: String) {
        guard scrolling else { return }
        scrollPaused = true; scrollStatus = reason
    }

    func resumeScroll() {
        guard scrolling else { return }
        guard let region = activeRegion,
              let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == region.displayID }),
              screen.frame == region.screenFrame, screen.backingScaleFactor == region.scale else {
            scrollStatus = "显示器配置已改变，请完成已有长图后重新框选。"; return
        }
        sourceApp?.activate()
        scrollPaused = false
        scrollStatus = "等待原页面稳定，正在检查重叠内容…"
    }

    func finishScroll() {
        guard scrolling, let stitcher else { return }
        captureTask?.cancel(); session = UUID()
        do {
            let image = try stitcher.finish()
            try repository?.add(image)
            endScroll()
            reload()
            message = "滚动长图已暂存"
            showShelf?()
        } catch {
            scrollPaused = true
            scrollStatus = error.localizedDescription
            let token = session
            captureTask = Task { await self.sampleLoop(token: token) }
        }
    }

    func cancelScroll() {
        captureTask?.cancel(); session = UUID()
        endScroll(); message = "已取消本次滚动截图，其他截图仍保留"
    }

    private func endScroll() {
        scrolling = false; capturing = false; scrollPaused = false
        stitcher = nil; scrollPreview = nil; activeRegion = nil
        hideScrollHUD?(); hotKeys.enableEscape(false)
    }

    func reload() {
        guard let repository else { return }
        clips = repository.state.clips
        canUndo = repository.state.deleted != nil
        thumbnails = thumbnails.filter { id, _ in clips.contains { $0.id == id } }
        for clip in clips where thumbnails[clip.id] == nil {
            if let image = try? ImageTools.load(repository.imageURL(clip)) { thumbnails[clip.id] = ImageTools.thumbnail(image) }
        }
    }

    func updateNote(_ id: UUID, _ text: String) {
        do { try repository?.updateNote(id: id, note: text); clips = repository?.state.clips ?? [] }
        catch { errorMessage = error.localizedDescription }
    }
    func move(_ id: UUID, to index: Int) {
        guard !busy else { return }
        do { try repository?.move(id: id, to: index); reload() }
        catch { errorMessage = error.localizedDescription }
    }
    func remove(_ id: UUID) {
        do { try repository?.remove(id: id); reload(); message = "已删除，可撤销最近一次删除" }
        catch { errorMessage = error.localizedDescription }
    }
    func undo() {
        do { try repository?.undoRemove(); reload(); message = "已恢复截图" }
        catch { errorMessage = error.localizedDescription }
    }
    func preview(_ clip: Clip) {
        guard let repository else { return }
        do { showImage?(try ImageTools.load(repository.imageURL(clip)), "截图预览") }
        catch { errorMessage = error.localizedDescription }
    }
    func copy(_ clip: Clip) {
        guard let repository else { return }
        do {
            let image = try ImageTools.load(repository.imageURL(clip))
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: .zero)]) else { throw ShelfError.message("复制失败。") }
            message = "已复制这张截图"
        } catch { errorMessage = error.localizedDescription }
    }
    func export() {
        guard let repository else { return }
        do {
            let items = try clips.map { CompositionItem(image: try ImageTools.load(repository.imageURL($0)), note: $0.note) }
            showImage?(try LongImageComposer.compose(items, maxWidth: exportWidth), "拼接长图")
        } catch { errorMessage = error.localizedDescription }
    }
    func pasteAll() {
        guard !busy, let repository else { return }
        paste.start(clips: clips, directory: repository.directory)
        if paste.running { hotKeys.enableEscape(true); hideShelf?(); showPasteHUD?() }
    }
}
