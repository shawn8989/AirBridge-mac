import Foundation
import Network

struct FileClientConfiguration {
    let endpoint: NWEndpoint
    let macID: String
    let deviceID: String
    let secret: Data
}

/// A separate connection and queue keep bulk data out of the input/video stream.
// Mutable state is confined to queue; cancellation also enters that queue.
final class FileRPC: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Wield.FileClient", qos: .utility)
    private let connection: NWConnection
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var buffer = Data()
    private var closed = false
    init(_ configuration: FileClientConfiguration) {
        connection = NWConnection(to: configuration.endpoint, using: WieldSecureTransport.parameters(keys: [
            configuration.deviceID: WieldSecureTransport.key(secret: configuration.secret, purpose: "files")]))
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.fail(error) }
        }
        connection.start(queue: queue)
        queue.async { self.receive() }
    }
    func close() { queue.async { self.fail(CancellationError()) } }
    func authenticate(_ configuration: FileClientConfiguration) async throws {
        let reply = try await request(["op": "hello", "deviceID": configuration.deviceID])
        guard reply["macID"] as? String == configuration.macID,
              let nonceText = reply["nonce"] as? String, let nonce = Data(base64Encoded: nonceText), nonce.count == 32,
              let proofText = reply["proof"] as? String, let proof = Data(base64Encoded: proofText),
              WieldSecureTransport.verifies(proof, secret: configuration.secret, nonce: nonce, context: "file-server:" + configuration.macID) else {
            throw RemoteError.message("This file connection could not verify your Mac. Scan its pairing QR again.")
        }
        let answer = WieldSecureTransport.proof(secret: configuration.secret, nonce: nonce, context: "file-client:" + configuration.macID)
        _ = try await request(["op": "auth", "proof": answer.base64EncodedString()])
    }
    func request(_ payload: [String: Any]) async throws -> [String: Any] {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.closed else { continuation.resume(throwing: RemoteError.message("Connection closed. Retry to reconnect.")); return }
                    let id = UUID().uuidString
                    var request = payload; request["id"] = id
                    do {
                        var data = try JSONSerialization.data(withJSONObject: request)
                        data.append(10)
                        self.pending[id] = continuation
                        self.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                            if let error { self?.fail(error) }
                        })
                        self.queue.asyncAfter(deadline: .now() + 30) {
                            guard self.pending[id] != nil else { return }
                            self.fail(RemoteError.message("The Mac stopped responding. Check its connection and retry."))
                        }
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { self.close() })
    }
    private func fail(_ error: Error) {
        guard !closed else { return }; closed = true
        let waiting = pending.values; pending.removeAll()
        connection.cancel()
        for continuation in waiting { continuation.resume(throwing: error) }
    }
    private func receive() {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data {
                self.buffer.append(data)
                guard self.buffer.count <= 1024 * 1024 else { self.fail(RemoteError.message("Invalid file response.")); return }
                while let newline = self.buffer.firstIndex(of: 10) {
                    let line = Data(self.buffer.prefix(upTo: newline)); self.buffer.removeSubrange(...newline)
                    guard let response = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let id = response["id"] as? String, let continuation = self.pending.removeValue(forKey: id) else {
                        self.fail(RemoteError.message("Invalid file response.")); return
                    }
                    if response["ok"] as? Bool == true { continuation.resume(returning: response) }
                    else { continuation.resume(throwing: RemoteError.message(response["error"] as? String ?? "File operation failed.")) }
                }
            }
            if let error { self.fail(error) }
            else if complete { self.fail(RemoteError.message("Connection interrupted. Retry to start the transfer again.")) }
            else { self.receive() }
        }
    }
}

