import Foundation
import Network

final class SecureFileServer {
    private let queue = DispatchQueue(label: "Wield.Files", qos: .utility)
    private let security = SecurityManager()
    private let macID: String
    private let macName: String
    private var listener: NWListener?
    private var sessions: [UUID: Session] = [:]
    private var generation = UUID()
    init(macID: String, macName: String) { self.macID = macID; self.macName = macName }

    private final class Session {
        let id = UUID()
        let connection: NWConnection
        var buffer = Data()
        var deviceID: String?
        var nonce: Data?
        var authenticated = false
        var authenticatedSecret: Data?
        var transfer: FileTransferHandle?
        var lastActivity = Date()
        init(_ connection: NWConnection) { self.connection = connection }
    }

    func restart(keys: [String: Data]) {
        queue.async {
            self.generation = UUID()
            let generation = self.generation
            self.listener?.cancel(); self.listener = nil
            guard !keys.isEmpty else { return }
            do {
                let listener = try NWListener(using: WieldSecureTransport.parameters(keys: keys),
                    on: NWEndpoint.Port(rawValue: WieldSecureTransport.filePort)!)
                self.listener = listener
                listener.service = NWListener.Service(name: self.macName, type: WieldSecureTransport.fileServiceType)
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self, self.generation == generation, self.listener != nil else { connection.cancel(); return }
                    self.accept(connection)
                }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self, self.generation == generation else { return }
                    if case .failed = state {
                        self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                            guard let self, self.generation == generation else { return }
                            self.restart(keys: self.security.secureKeys(purpose: "files"))
                        }
                    }
                }
                listener.start(queue: self.queue)
            } catch { print("[Wield Files] Listener unavailable: \(error.localizedDescription)") }
        }
    }
    func stop() {
        queue.async {
            self.generation = UUID(); self.listener?.cancel(); self.listener = nil
            for session in Array(self.sessions.values) { self.close(session) }
        }
    }
    func revoke(_ deviceID: String) {
        queue.async { for session in Array(self.sessions.values) where session.deviceID == deviceID { self.close(session) } }
    }
    private func accept(_ connection: NWConnection) {
        guard sessions.count < 16 else { connection.cancel(); return }
        let session = Session(connection); sessions[session.id] = session
        connection.stateUpdateHandler = { [weak self, weak session] state in
            guard let self, let session else { return }
            switch state { case .failed, .cancelled: self.close(session); default: break }
        }
        connection.start(queue: queue)
        receive(session)
        reap(session)
    }
    private func reap(_ session: Session) {
        queue.asyncAfter(deadline: .now() + 15) { [weak self, weak session] in
            guard let self, let session, self.sessions[session.id] != nil else { return }
            let idle = Date().timeIntervalSince(session.lastActivity)
            if idle > (session.authenticated ? 90 : 15) { self.close(session) }
            else { self.reap(session) }
        }
    }
    private func close(_ session: Session) {
        sessions[session.id] = nil
        session.transfer = nil // closes the file and removes any partial upload
        session.connection.cancel()
    }
    private func receive(_ session: Session) {
        session.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak session] data, _, complete, error in
            guard let self, let session, self.sessions[session.id] != nil else { return }
            if let data {
                session.buffer.append(data)
                guard session.buffer.count <= 1024 * 1024 else { self.close(session); return }
                while let newline = session.buffer.firstIndex(of: 10) {
                    let line = Data(session.buffer.prefix(upTo: newline))
                    session.buffer.removeSubrange(...newline)
                    self.handle(line, session)
                    if self.sessions[session.id] == nil { return }
                }
            }
            if complete || error != nil { self.close(session) }
            else { self.receive(session) }
        }
    }
    private func handle(_ data: Data, _ session: Session) {
        var requestID = ""
        do {
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = request["id"] as? String, id.count <= 64,
                  let op = request["op"] as? String else { throw RemoteError.message("Invalid request.") }
            requestID = id
            session.lastActivity = Date()
            var response: [String: Any] = [:]
            if op == "hello" {
                guard session.deviceID == nil, let deviceID = request["deviceID"] as? String,
                      let secret = security.secureSecret(for: deviceID) else { throw RemoteError.message("Pairing required.") }
                session.deviceID = deviceID
                let nonce = security.generateNonce(length: 32); session.nonce = nonce
                response = ["macID": macID, "nonce": nonce.base64EncodedString(),
                    "proof": WieldSecureTransport.proof(secret: secret, nonce: nonce, context: "file-server:" + macID).base64EncodedString()]
            } else if op == "auth" {
                guard !session.authenticated, let deviceID = session.deviceID, let nonce = session.nonce,
                      let secret = security.secureSecret(for: deviceID), let encoded = request["proof"] as? String,
                      let proof = Data(base64Encoded: encoded),
                      WieldSecureTransport.verifies(proof, secret: secret, nonce: nonce, context: "file-client:" + macID) else {
                    throw RemoteError.message("Pairing was revoked or changed.")
                }
                session.authenticated = true; session.authenticatedSecret = secret; session.nonce = nil
            } else {
                guard session.authenticated, let deviceID = session.deviceID,
                      let current = security.secureSecret(for: deviceID), current == session.authenticatedSecret else {
                    session.authenticated = false
                    throw RemoteError.message("Pairing required.")
                }
                let store = SharedFolderStore.shared
                if let transfer = session.transfer, !store.contains(transfer.rootID) {
                    session.transfer = nil
                    throw RemoteError.message("This folder is no longer shared.")
                }
                switch op {
                case "roots":
                    response["folders"] = store.snapshot().map { ["id": $0.id, "name": $0.name] }
                case "list":
                    guard let rootID = request["root"] as? String else { throw RemoteError.message("Choose a shared folder.") }
                    let root = try store.root(rootID)
                    let offset = request["offset"] as? Int ?? 0
                    guard offset >= 0 else { throw RemoteError.message("Invalid page.") }
                    let (entries, more) = try root.entries(request["path"] as? String ?? "", offset: offset)
                    response = ["entries": entries, "more": more]
                case "download", "upload":
                    guard session.transfer == nil, let rootID = request["root"] as? String else { throw RemoteError.message("Finish the current transfer first.") }
                    let root = try store.root(rootID)
                    let transfer: FileTransferHandle
                    if op == "download" {
                        transfer = try FileTransferHandle(download: request["path"] as? String ?? "", rootID: rootID, root: root)
                    } else {
                        guard let name = request["name"] as? String, let number = request["size"] as? NSNumber else { throw RemoteError.message("Invalid upload.") }
                        transfer = try FileTransferHandle(upload: name, size: number.int64Value,
                            directory: request["path"] as? String ?? "", rootID: rootID, root: root)
                    }
                    session.transfer = transfer
                    response = ["transfer": transfer.id, "size": transfer.size, "name": transfer.name]
                case "read", "write", "commit", "cancel":
                    guard let transfer = session.transfer, request["transfer"] as? String == transfer.id else { throw RemoteError.message("Transfer expired. Please retry.") }
                    if op == "read" {
                        guard (request["offset"] as? NSNumber)?.int64Value == transfer.offset else { throw RemoteError.message("Download interrupted. Retry from the beginning.") }
                        let chunk = try transfer.readChunk()
                        response = ["data": chunk.base64EncodedString(), "offset": transfer.offset, "done": transfer.offset == transfer.size]
                        if transfer.offset == transfer.size { session.transfer = nil }
                    } else if op == "write" {
                        guard (request["offset"] as? NSNumber)?.int64Value == transfer.offset,
                              let encoded = request["data"] as? String, let chunk = Data(base64Encoded: encoded) else { throw RemoteError.message("Upload interrupted. Retry from the beginning.") }
                        try transfer.writeChunk(chunk); response["offset"] = transfer.offset
                    } else if op == "commit" {
                        response["name"] = try transfer.commit(); session.transfer = nil
                    } else { session.transfer = nil }
                default: throw RemoteError.message("Unsupported file operation.")
                }
            }
            response["id"] = id; response["ok"] = true
            send(response, session)
        } catch {
            session.transfer = nil
            send(["id": requestID, "ok": false, "error": error.localizedDescription], session)
            if !session.authenticated { queue.asyncAfter(deadline: .now() + 0.2) { self.close(session) } }
        }
    }
    private func send(_ response: [String: Any], _ session: Session) {
        guard var data = try? JSONSerialization.data(withJSONObject: response) else { close(session); return }
        data.append(10)
        session.connection.send(content: data, completion: .contentProcessed { [weak self, weak session] error in
            if error != nil, let self, let session { self.close(session) }
        })
    }
}
