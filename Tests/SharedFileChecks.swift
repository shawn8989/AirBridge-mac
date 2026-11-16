import Foundation

@main struct SharedFileChecks {
    static func main() throws {
        let fm = FileManager.default
        let workspace = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workspace) }
        let rootURL = workspace.appendingPathComponent("shared")
        try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let outside = workspace.appendingPathComponent("outside.txt")
        try Data("private".utf8).write(to: outside)
        try fm.createSymbolicLink(at: rootURL.appendingPathComponent("link.txt"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: rootURL.appendingPathComponent("escape"), withDestinationURL: workspace)
        let root = try FolderDescriptor(url: rootURL)
        for path in ["../outside.txt", "/outside.txt", "link.txt", "escape/outside.txt", "a/../../outside.txt", "a//b", "a\0b"] {
            do { let _ = try root.file(path); fatalError("Escaped root through \(path)") } catch {}
        }
        let original = rootURL.appendingPathComponent("document.txt")
        try Data("original".utf8).write(to: original)
        let body = Data(repeating: 42, count: 100_001)
        let upload = try FileTransferHandle(upload: "document.txt", size: Int64(body.count), directory: "", rootID: "root", root: root)
        for offset in stride(from: 0, to: body.count, by: 48 * 1024) {
            try upload.writeChunk(body.subdata(in: offset..<min(offset + 48 * 1024, body.count)))
        }
        let savedName = try upload.commit()
        precondition(savedName == "document (1).txt")
        let originalData = try Data(contentsOf: original)
        precondition(originalData == Data("original".utf8))
        let download = try FileTransferHandle(download: "document (1).txt", rootID: "root", root: root)
        var result = Data()
        while download.offset < download.size { result.append(try download.readChunk()) }
        precondition(result == body)
        var partial: FileTransferHandle? = try FileTransferHandle(upload: "partial.txt", size: 100, directory: "", rootID: "root", root: root)
        try partial!.writeChunk(Data([1,2,3]))
        do { let _ = try partial!.commit(); fatalError("Incomplete upload committed") } catch {}
        partial = nil
        let remainingFiles = try fm.contentsOfDirectory(atPath: rootURL.path)
        precondition(!remainingFiles.contains(where: { $0.hasPrefix(".wield-upload-") }))
        let empty = try FileTransferHandle(upload: "empty.txt", size: 0, directory: "", rootID: "root", root: root)
        _ = try empty.commit()
        let emptyData = try Data(contentsOf: rootURL.appendingPathComponent("empty.txt"))
        precondition(emptyData.isEmpty)
        print("Files: traversal, symlink escape, chunking, collision, atomic completion, cancellation, empty file passed")
    }
}
