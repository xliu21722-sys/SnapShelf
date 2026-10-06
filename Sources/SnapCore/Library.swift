import Foundation
import CoreGraphics

public struct Clip: Codable, Identifiable, Equatable {
    public let id: UUID
    public let filename: String
    public let width: Int
    public let height: Int
    public var note: String
    public let createdAt: Date

    public init(id: UUID = UUID(), width: Int, height: Int, note: String = "") {
        self.id = id
        self.filename = id.uuidString + ".png"
        self.width = width
        self.height = height
        self.note = note
        self.createdAt = Date()
    }
}

public struct DeletedClip: Codable {
    public let clip: Clip
    public let index: Int
}

public struct LibraryState: Codable {
    public var version = 1
    public var clips: [Clip] = []
    public var deleted: DeletedClip?
    public init() {}
}

public enum ShelfError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

/// Commit the manifest before discarding any previous image. Failed writes never
/// replace the in-memory state. A deleted clip remains recoverable across restarts.
public final class LibraryRepository {
    public let directory: URL
    public private(set) var state: LibraryState
    private let manifest: URL

    public init(directory: URL) throws {
        self.directory = directory
        self.manifest = directory.appendingPathComponent("library.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: manifest.path) {
            state = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: manifest))
            guard state.version == 1 else { throw ShelfError.message("暂存数据版本不受支持，原文件已保留。") }
            let entries = state.clips + (state.deleted.map { [$0.clip] } ?? [])
            guard Set(entries.map(\.id)).count == entries.count,
                  entries.allSatisfy({ $0.filename == $0.id.uuidString + ".png" && $0.width > 0 && $0.height > 0 }) else {
                throw ShelfError.message("暂存记录无效，原文件已保留，请勿覆盖。")
            }
        } else {
            state = LibraryState()
        }
    }

    public func imageURL(_ clip: Clip) -> URL { directory.appendingPathComponent(clip.filename) }

    @discardableResult
    public func add(_ image: CGImage, note: String = "") throws -> Clip {
        let clip = Clip(width: image.width, height: image.height, note: note)
        try ImageTools.png(image).write(to: imageURL(clip), options: .atomic)
        var next = state
        next.clips.append(clip)
        do { try commit(next) }
        catch {
            try? FileManager.default.removeItem(at: imageURL(clip))
            throw error
        }
        return clip
    }

    public func updateNote(id: UUID, note: String) throws {
        var next = state
        guard let i = next.clips.firstIndex(where: { $0.id == id }) else { return }
        next.clips[i].note = note
        try commit(next)
    }

    public func move(id: UUID, to index: Int) throws {
        var next = state
        guard let old = next.clips.firstIndex(where: { $0.id == id }) else { return }
        let clip = next.clips.remove(at: old)
        next.clips.insert(clip, at: max(0, min(index, next.clips.count)))
        try commit(next)
    }

    public func remove(id: UUID) throws {
        var next = state
        guard let i = next.clips.firstIndex(where: { $0.id == id }) else { return }
        let expired = next.deleted?.clip
        next.deleted = DeletedClip(clip: next.clips.remove(at: i), index: i)
        try commit(next)
        if let expired { try? FileManager.default.removeItem(at: imageURL(expired)) }
    }

    public func undoRemove() throws {
        var next = state
        guard let deleted = next.deleted else { return }
        next.clips.insert(deleted.clip, at: min(deleted.index, next.clips.count))
        next.deleted = nil
        try commit(next)
    }

    private func commit(_ next: LibraryState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(next).write(to: manifest, options: .atomic)
        state = next
    }
}
