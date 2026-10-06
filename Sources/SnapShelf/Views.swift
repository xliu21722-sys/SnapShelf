import SwiftUI
import UniformTypeIdentifiers
import SnapCore

private let ink = Color(red: 0.16, green: 0.19, blue: 0.27)
private let accent = Color(red: 0.29, green: 0.32, blue: 0.82)
private let canvas = Color(red: 0.96, green: 0.965, blue: 0.98)

struct ShelfView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var paste: PasteController
    @State private var dragging: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            captureButtons.padding(.horizontal, 22).padding(.bottom, 18)
            if let error = model.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.system(size: 12)).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(12).background(Color.orange.opacity(0.09)).padding(.horizontal, 22).padding(.bottom, 10)
            }
            HStack {
                Text("暂存清单").font(.system(size: 12, weight: .semibold))
                Text("\(model.totalCount)").font(.system(size: 11, weight: .bold, design: .rounded))
                    .padding(.horizontal, 7).padding(.vertical, 3).background(accent.opacity(0.09), in: Capsule())
                Spacer()
                if model.canUndo {
                    Button("撤销删除", systemImage: "arrow.uturn.backward", action: model.undo)
                        .buttonStyle(.plain).disabled(model.busy)
                } else { Text("拖动调整顺序").foregroundStyle(.secondary) }
            }.font(.system(size: 11)).padding(.horizontal, 24).padding(.bottom, 10)
            if model.clips.isEmpty { emptyState }
            else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(Array(model.clips.enumerated()), id: \.element.id) { index, clip in
                            clipCard(clip, index: index)
                                .onDrag { dragging = clip.id; return NSItemProvider(object: clip.id.uuidString as NSString) }
                                .onDrop(of: [UTType.text], delegate: ClipDrop(target: clip.id, model: model, dragging: $dragging))
                        }
                    }.padding(.horizontal, 22).padding(.bottom, 16)
                }
            }
            footer
        }
        .foregroundStyle(ink)
        .background(canvas)
        .tint(accent)
        .frame(minWidth: 450, minHeight: 570)
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model, paste: paste) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(accent.gradient).frame(width: 43, height: 43)
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 21)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("截图暂存").font(.system(size: 22, weight: .bold))
                Text("先收集，再整理。学习不用来回切换。").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.showSettings = true } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 16)).padding(9)
            }.buttonStyle(.plain).help("快捷键、权限与粘贴设置").accessibilityLabel("设置")
        }.padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 22)
    }

    private var captureButtons: some View {
        HStack(spacing: 10) {
            captureButton("框选截图", symbol: "viewfinder", key: model.screenshotKey, primary: true) { model.startCapture(scrolling: false) }
            captureButton("滚动长截图", symbol: "arrow.down.to.line.compact", key: model.scrollKey, primary: false) { model.startCapture(scrolling: true) }
        }.disabled(model.busy)
    }

    private func captureButton(_ title: String, symbol: String, key: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                Text("⌥ \(key)").font(.system(size: 10, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 4)
                    .background((primary ? Color.white : accent).opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
            }.padding(.horizontal, 12).frame(height: 46).frame(maxWidth: .infinity)
                .background(primary ? accent : Color.white, in: RoundedRectangle(cornerRadius: 11))
                .foregroundStyle(primary ? .white : ink)
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(primary ? Color.clear : Color.black.opacity(0.06)))
        }.buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 24)
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(accent.opacity(0.06)).frame(width: 126, height: 92).rotationEffect(.degrees(-9)).offset(x: -8, y: -4)
                RoundedRectangle(cornerRadius: 14).fill(.white).frame(width: 126, height: 92)
                    .shadow(color: accent.opacity(0.1), radius: 16, y: 6)
                Image(systemName: "photo.badge.plus").font(.system(size: 31, weight: .light)).foregroundStyle(accent.opacity(0.7))
            }.padding(.bottom, 10)
            Text("把第一张灵感放进来").font(.system(size: 18, weight: .semibold))
            Text("按 ⌥ \(model.screenshotKey) 框选题目、笔记或参考资料\n连续截图会按顺序保存在这里")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
            HStack(spacing: 17) {
                Label("自动暂存", systemImage: "tray.and.arrow.down")
                Label("不含鼠标", systemImage: "cursorarrow.slash")
                Label("本机保存", systemImage: "lock")
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 8)
            if !model.screenAllowed {
                Button("开启屏幕录制权限", action: model.requestScreenPermission)
                    .buttonStyle(.bordered).padding(.top, 6)
            }
            Spacer(minLength: 24)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func clipCard(_ clip: Clip, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(format: "%02d", index + 1)).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(accent)
                Text("\(clip.width) × \(clip.height)").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button { model.move(clip.id, to: index - 1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0)
                Button { model.move(clip.id, to: index + 1) } label: { Image(systemName: "arrow.down") }.disabled(index == model.clips.count - 1)
                Button { model.copy(clip) } label: { Image(systemName: "doc.on.doc") }.help("复制这张截图")
                Button { model.remove(clip.id) } label: { Image(systemName: "trash") }.help("删除截图，可撤销")
            }.buttonStyle(.plain).font(.system(size: 11)).disabled(model.busy)
            Button { model.preview(clip) } label: {
                Group {
                    if let thumbnail = model.thumbnails[clip.id] {
                        Image(nsImage: thumbnail).resizable().scaledToFit().frame(maxWidth: .infinity).frame(maxHeight: 190)
                    } else { Label("图片文件缺失", systemImage: "photo.badge.exclamationmark").frame(height: 70).frame(maxWidth: .infinity) }
                }.padding(8).background(canvas, in: RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "text.alignleft").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 4)
                TextField("加一句备注，比如：这题需要复习…", text: Binding(get: { clip.note }, set: { model.updateNote(clip.id, $0) }), axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 12)).lineLimit(1...5).disabled(model.busy)
            }
        }.padding(13).background(.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.black.opacity(0.05)))
    }

    private var footer: some View {
        VStack(spacing: 12) {
            if !paste.status.isEmpty {
                HStack(alignment: .top) {
                    Text(paste.status).font(.system(size: 11)).foregroundStyle(.secondary)
                    if paste.running { Button("停止", action: paste.cancel).font(.system(size: 11)) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.message.isEmpty { Text(model.message).font(.system(size: 11)).foregroundStyle(accent).frame(maxWidth: .infinity, alignment: .leading) }
            HStack(spacing: 10) {
                Button(action: model.export) {
                    Label("拼成长图", systemImage: "rectangle.portrait.on.rectangle.portrait")
                        .font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).frame(height: 40)
                        .background(canvas, in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain)
                Button(action: model.pasteAll) {
                    Label("粘贴到 Chrome", systemImage: "arrow.up.forward.square")
                        .font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 40)
                        .background(accent, in: RoundedRectangle(cornerRadius: 9)).foregroundStyle(.white)
                }.buttonStyle(.plain)
            }.disabled(model.clips.isEmpty || model.busy)
            Text("先在文档正文点好插入位置 · 自动粘贴为试用功能")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(18).padding(.horizontal, 4).background(.white)
            .overlay(alignment: .top) { Divider() }
    }
}

private struct ClipDrop: DropDelegate {
    let target: UUID
    let model: AppModel
    @Binding var dragging: UUID?
    func dropEntered(info: DropInfo) {
        guard let id = dragging, id != target, let index = model.clips.firstIndex(where: { $0.id == target }) else { return }
        model.move(id, to: index)
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var paste: PasteController
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("按你的习惯来").font(.title2.bold()); Spacer(); Button("完成") { model.showSettings = false } }
            GroupBox("两个键就能截图") {
                VStack(spacing: 12) {
                    shortcut("普通截图", value: model.screenshotKey, scrolling: false)
                    shortcut("滚动长截图", value: model.scrollKey, scrolling: true)
                }.padding(10)
            }
            GroupBox("粘贴与导出") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("每张图片等待"); Slider(value: $paste.interval, in: 0.8...5, step: 0.2); Text(String(format: "%.1f 秒", paste.interval)).monospacedDigit() }
                    Text("网络慢或图片大时调高等待时间。实际插入及保存状态需在飞书检查。").font(.caption).foregroundStyle(.secondary)
                    Picker("长图最大宽度", selection: $model.exportWidth) {
                        Text("1600 px").tag(1600); Text("1200 px").tag(1200); Text("800 px").tag(800)
                    }
                }.padding(10)
            }
            GroupBox("系统权限") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Label("屏幕录制：用于截图", systemImage: "viewfinder"); Spacer(); Button("设置") { model.requestScreenPermission() } }
                    HStack { Label("辅助功能：用于自动粘贴", systemImage: "keyboard"); Spacer(); Button("设置") { _ = PasteController.trusted(prompt: true); model.openSettings("Privacy_Accessibility") } }
                    Text("图片和备注只保存在本机。截图不包含系统鼠标指针；网页的悬浮提示仍属于画面内容。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(10)
            }
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(24).frame(width: 470).tint(accent)
    }
    private func shortcut(_ title: String, value: String, scrolling: Bool) -> some View {
        HStack {
            Text(title); Spacer(); Text("⌥ Option +").foregroundStyle(.secondary)
            Picker(title, selection: Binding(get: { value }, set: { model.changeShortcut(scrolling: scrolling, letter: $0) })) {
                ForEach(HotKeys.keyCodes.keys.sorted(), id: \.self) { Text($0).tag($0) }
            }.labelsHidden().frame(width: 65)
        }
    }
}

struct ScrollHUDView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Circle().fill(model.scrollPaused ? Color.orange : Color.green).frame(width: 7, height: 7)
                Text(model.scrollPaused ? "已暂停" : "滚动长截图").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(model.scrollHeight) px").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            if let image = model.scrollPreview {
                ScrollView { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity) }
                    .frame(height: 160).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Text(model.scrollStatus).font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("取消", action: model.cancelScroll).buttonStyle(.borderless)
                Spacer()
                if model.scrollPaused { Button("继续", action: model.resumeScroll) }
                Button("完成", action: model.finishScroll).buttonStyle(.borderedProminent)
            }.font(.system(size: 12))
            Text("向下滚动 · Esc 取消").font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(16).frame(width: 230).background(canvas).tint(accent)
    }
}

struct ImagePreviewView: View {
    let image: CGImage
    @State private var message = ""
    @State private var actualSize = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(image.width) × \(image.height) px").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Toggle("原始尺寸", isOn: $actualSize).toggleStyle(.checkbox)
                Button("复制图片", systemImage: "doc.on.doc", action: copy)
                Button("保存 PNG…", systemImage: "square.and.arrow.down", action: save).buttonStyle(.borderedProminent)
            }.padding(16)
            if !message.isEmpty { Text(message).font(.caption).padding(.bottom, 10) }
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high)
                        .frame(width: actualSize ? CGFloat(image.width) : min(CGFloat(image.width), geometry.size.width - 32),
                               height: (actualSize ? CGFloat(image.width) : min(CGFloat(image.width), geometry.size.width - 32)) * CGFloat(image.height) / CGFloat(image.width))
                        .padding(16)
                }.background(canvas)
            }
        }.tint(accent).frame(minWidth: 550, minHeight: 450)
    }
    private func copy() {
        NSPasteboard.general.clearContents()
        message = NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: .zero)]) ? "已复制图片" : "复制失败，请重试"
    }
    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "截图长图-\(formatter.string(from: Date())).png"
        if panel.runModal() == .OK, let url = panel.url {
            do { try ImageTools.png(image).write(to: url, options: .atomic); message = "已保存到 \(url.lastPathComponent)" }
            catch { message = error.localizedDescription }
        }
    }
}

struct PasteHUDView: View {
    @ObservedObject var paste: PasteController
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: paste.running ? "doc.on.clipboard" : "info.circle").foregroundStyle(accent)
                Text(paste.running ? "正在粘贴到 Chrome" : "粘贴操作已结束").font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            Text(paste.status).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if paste.running {
                ProgressView().progressViewStyle(.linear)
                HStack { Text("请勿操作目标文档").font(.system(size: 10)).foregroundStyle(.secondary); Spacer(); Button("停止 · Esc", action: paste.cancel) }
            } else { HStack { Spacer(); Button("关闭", action: dismiss) } }
        }.padding(16).frame(width: 300).background(canvas).tint(accent)
    }
}
