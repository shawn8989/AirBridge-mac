import Foundation
import Combine
import Darwin

struct SharedFolder: Codable, Identifiable {
    let id: String
    let name: String
    let bookmark: Data
}

final class SharedFolderStore: ObservableObject {
    static let shared = SharedFolderStore()
    @Published private(set) var folders: [SharedFolder]
    private let lock = NSLock()
    private var records: [SharedFolder]
    init() {
        let saved = UserDefaults.standard.data(forKey: "sharedFolders.v1")
        let decoded = saved.flatMap { try? JSONDecoder().decode([SharedFolder].self, from: $0) } ?? []
        folders = decoded; records = decoded
    }
    func add(_ url: URL) throws {
        let resolved = url.resolvingSymlinksInPath()
        let bookmark = try resolved.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let folder = SharedFolder(id: UUID().uuidString, name: resolved.lastPathComponent, bookmark: bookmark)
        lock.lock(); records.append(folder); let copy = records; lock.unlock()
        publish(copy)
    }
    func remove(_ id: String) {
        lock.lock(); records.removeAll { $0.id == id }; let copy = records; lock.unlock()
        publish(copy)
    }
    func snapshot() -> [SharedFolder] { lock.lock(); defer { lock.unlock() }; return records }
    func contains(_ id: String) -> Bool { snapshot().contains { $0.id == id } }
    func root(_ id: String) throws -> FolderDescriptor {
        guard let folder = snapshot().first(where: { $0.id == id }) else { throw RemoteError.message("This folder is no longer shared.") }
        var stale = false
        let url = try URL(resolvingBookmarkData: folder.bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw RemoteError.message("Choose this shared folder again in Wield Host.") }
        return try FolderDescriptor(url: url)
    }
    private func publish(_ values: [SharedFolder]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(values), forKey: "sharedFolders.v1")
        DispatchQueue.main.async { self.folders = values }
    }
}

/// Descend from an open directory, rejecting links at EVERY component. A
/// string-prefix check alone is not enough: a symlink can change after checking.
final class FolderDescriptor {
    let fd: Int32
    private let url: URL
    private let scoped: Bool
    init(url: URL) throws {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
        fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw RemoteError.message("Cannot open the shared folder. Check its permissions on the Mac.")
        }
    }
    deinit { close(fd); if scoped { url.stopAccessingSecurityScopedResource() } }

    static func components(_ path: String) throws -> [String] {
        guard !path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096 else { throw RemoteError.message("Invalid file path.") }
        if path.isEmpty { return [] }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else { throw RemoteError.message("Invalid file path.") }
        return parts
    }
    func directory(_ path: String) throws -> Int32 {
        var current = dup(fd)
        guard current >= 0 else { throw RemoteError.message("Cannot open folder.") }
        do {
            for component in try Self.components(path) {
                let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw RemoteError.message("The folder is unavailable or contains a symbolic link.") }
                close(current); current = next
            }
            return current
        } catch { close(current); throw error }
    }
    func file(_ path: String) throws -> Int32 {
        var parts = try Self.components(path)
        guard let name = parts.popLast() else { throw RemoteError.message("Choose a file.") }
        let parent = try directory(parts.joined(separator: "/")); defer { close(parent) }
        let file = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw RemoteError.message("The file is unavailable or is a symbolic link.") }
        var info = stat()
        guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { close(file); throw RemoteError.message("Only regular files can be transferred.") }
        return file
    }
    func entries(_ path: String, offset: Int) throws -> ([[String: Any]], Bool) {
        let directory = try self.directory(path)
        guard let stream = fdopendir(directory) else { close(directory); throw RemoteError.message("Cannot read folder.") }
        defer { closedir(stream) }
        var result: [[String: Any]] = []
        var seen = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name.hasPrefix(".") { continue }
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFDIR else { continue }
            if seen < offset { seen += 1; continue }
            if result.count == 200 { return (result, true) }
            result.append(["name": name, "directory": kind == S_IFDIR, "size": max(0, info.st_size)])
        }
        return (result, false)
    }
}

final class FileTransferHandle {
    let id = UUID().uuidString
    let rootID: String
    let root: FolderDescriptor
    let fd: Int32
    let parent: Int32?
    let temporaryName: String?
    let name: String
    let size: Int64
    var offset: Int64 = 0
    private var committed = false
    private var initialModified: timespec?

    init(download path: String, rootID: String, root: FolderDescriptor) throws {
        self.rootID = rootID; self.root = root
        fd = try root.file(path)
        var info = stat(); fstat(fd, &info)
        initialModified = info.st_mtimespec
        size = info.st_size; name = (path as NSString).lastPathComponent
        parent = nil; temporaryName = nil
    }
    init(upload name: String, size: Int64, directory: String, rootID: String, root: FolderDescriptor) throws {
        let parts = try FolderDescriptor.components(name)
        guard parts.count == 1, !name.hasPrefix("."), size >= 0 else { throw RemoteError.message("Invalid upload name or size.") }
        self.rootID = rootID; self.root = root; self.name = name; self.size = size
        let parent = try root.directory(directory)
        self.parent = parent
        let temp = ".wield-upload-" + UUID().uuidString
        temporaryName = temp
        fd = openat(parent, temp, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        if fd < 0 { close(parent); throw RemoteError.message("Cannot create the upload. Check disk space and folder permissions.") }
    }
    deinit {
        close(fd)
        if let parent {
            if !committed, let temporaryName { unlinkat(parent, temporaryName, 0) }
            close(parent)
        }
    }
    func readChunk() throws -> Data {
        guard parent == nil else { throw RemoteError.message("Not a download.") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size == size,
              info.st_mtimespec.tv_sec == initialModified?.tv_sec,
              info.st_mtimespec.tv_nsec == initialModified?.tv_nsec else {
            throw RemoteError.message("The file changed on the Mac. Retry the download.")
        }
        var bytes = [UInt8](repeating: 0, count: 48 * 1024)
        let remaining = max(0, min(Int64(bytes.count), size - offset))
        let count = Darwin.read(fd, &bytes, Int(remaining))
        guard count >= 0, count > 0 || offset == size else { throw RemoteError.message("The file changed or could not be read. Retry the download.") }
        offset += Int64(count)
        return Data(bytes.prefix(count))
    }
    func writeChunk(_ data: Data) throws {
        guard parent != nil, data.count <= 48 * 1024, Int64(data.count) <= size - offset else { throw RemoteError.message("Invalid upload chunk.") }
        try data.withUnsafeBytes { raw in
            var done = 0
            while done < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: done), raw.count - done)
                guard count > 0 else { throw RemoteError.message("Upload failed. Check disk space on the Mac.") }
                done += count
            }
        }
        offset += Int64(data.count)
    }
    func commit() throws -> String {
        guard offset == size, let parent, let temporaryName else { throw RemoteError.message("The upload is incomplete.") }
        guard fsync(fd) == 0 else { throw RemoteError.message("Could not save the upload.") }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for suffix in 0...9999 {
            let candidate = suffix == 0 ? name : "\(base) (\(suffix))" + (ext.isEmpty ? "" : ".\(ext)")
            // RENAME_EXCL atomically fails if the destination already exists.
            // Never check-then-overwrite: a second upload may race this one.
            if renameatx_np(parent, temporaryName, parent, candidate, UInt32(RENAME_EXCL)) == 0 {
                committed = true
                return candidate
            }
            guard errno == EEXIST else { throw RemoteError.message("Could not finish the upload. The existing files were preserved.") }
        }
        throw RemoteError.message("Too many files have this name. Rename the file and retry.")
    }
}
