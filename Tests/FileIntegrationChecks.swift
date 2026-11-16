import Foundation
import Network

@main struct FileIntegrationChecks {
    static func main() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let original = Data(repeating: 37, count: 150_003)
        try original.write(to: base.appendingPathComponent("test.bin"))
        let folders = SharedFolderStore.shared
        try folders.add(base)
        let root = folders.snapshot().last!
        let security = SecurityManager()
        let device = UUID().uuidString, mac = UUID().uuidString
        let secret = security.generateSharedSecret()
        try security.storeSecureSecret(secret, for: device)
        let server = SecureFileServer(macID: mac, macName: "CI Mac")
        server.restart(keys: security.secureKeys(purpose: "files"))
        defer {
            server.stop(); folders.remove(root.id); security.deleteSecureSecret(for: device)
            try? fm.removeItem(at: base)
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let config = FileClientConfiguration(endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: WieldSecureTransport.filePort)!), macID: mac, deviceID: device, secret: secret)
        let rpc = FileRPC(config); defer { rpc.close() }
        try await rpc.authenticate(config)
        let roots = try await rpc.request(["op": "roots"])
        precondition((roots["folders"] as? [[String: Any]])?.contains(where: { $0["id"] as? String == root.id }) == true)
        let download = try await rpc.request(["op": "download", "root": root.id, "path": "test.bin"])
        let transfer = download["transfer"] as! String
        var received = Data()
        while received.count < original.count {
            let chunk = try await rpc.request(["op": "read", "transfer": transfer, "offset": received.count])
            received.append(Data(base64Encoded: chunk["data"] as! String)!)
        }
        precondition(received == original)
        let upload = try await rpc.request(["op": "upload", "root": root.id, "path": "", "name": "test.bin", "size": original.count])
        let uploadID = upload["transfer"] as! String
        for offset in stride(from: 0, to: original.count, by: 48 * 1024) {
            let chunk = original.subdata(in: offset..<min(offset + 48 * 1024, original.count))
            _ = try await rpc.request(["op": "write", "transfer": uploadID, "offset": offset, "data": chunk.base64EncodedString()])
        }
        let done = try await rpc.request(["op": "commit", "transfer": uploadID])
        precondition(done["name"] as? String == "test (1).bin")
        let uploaded = try Data(contentsOf: base.appendingPathComponent("test (1).bin"))
        precondition(uploaded == original)
        do {
            _ = try await rpc.request(["op": "download", "root": root.id, "path": "../outside"])
            fatalError("Traversal accepted over the wire")
        } catch {}
        let pending = try await rpc.request(["op": "upload", "root": root.id, "path": "", "name": "cancel.bin", "size": 100])
        _ = try await rpc.request(["op": "cancel", "transfer": pending["transfer"] as! String])
        let pending2 = try await rpc.request(["op": "upload", "root": root.id, "path": "", "name": "revoked.bin", "size": 100])
        folders.remove(root.id)
        do {
            _ = try await rpc.request(["op": "write", "transfer": pending2["transfer"] as! String, "offset": 0, "data": Data([1]).base64EncodedString()])
            fatalError("Revoked folder accepted a write")
        } catch {}
        // Rotation must invalidate an already-authenticated connection too.
        try security.storeSecureSecret(security.generateSharedSecret(), for: device)
        do { _ = try await rpc.request(["op": "roots"]); fatalError("Replaced key retained access") } catch {}
        try security.storeSecureSecret(secret, for: device)
        let revoked = FileRPC(config); defer { revoked.close() }
        try await revoked.authenticate(config)
        security.deleteSecureSecret(for: device)
        do { _ = try await revoked.request(["op": "roots"]); fatalError("Revoked pairing retained access") } catch {}
        let files = try fm.contentsOfDirectory(atPath: base.path)
        precondition(!files.contains(where: { $0.hasPrefix(".wield-upload-") }))
        print("Real encrypted client/server: authentication, download, upload, collision, traversal, cancellation, folder and device revocation passed")
    }
}
