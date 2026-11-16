import Foundation
import Network

final class Probe {
    let queue = DispatchQueue(label: "secure-transport-test")
    var listener: NWListener?
    var server: NWConnection?
    var client: NWConnection?
    var completion: CheckedContinuation<Bool, Never>?
    var finished = false

    func run(identity: String, secret: Data, accepted: [String: Data]) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                self.completion = continuation
                do {
                    let listener = try NWListener(using: WieldSecureTransport.parameters(keys: accepted), on: .any)
                    self.listener = listener
                    listener.newConnectionHandler = { connection in
                        self.server = connection
                        connection.start(queue: self.queue)
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 16) { data, _, _, _ in
                            if data == Data("hello".utf8) {
                                connection.send(content: Data("verified".utf8), completion: .contentProcessed { _ in })
                            }
                        }
                    }
                    listener.stateUpdateHandler = { state in
                        guard case .ready = state, let port = listener.port else { return }
                        let client = NWConnection(host: "127.0.0.1", port: port,
                            using: WieldSecureTransport.parameters(keys: [identity: secret]))
                        self.client = client
                        client.stateUpdateHandler = { state in
                            switch state {
                            case .ready:
                                client.send(content: Data("hello".utf8), completion: .contentProcessed { _ in })
                                client.receive(minimumIncompleteLength: 1, maximumLength: 16) { data, _, _, _ in
                                    self.finish(data == Data("verified".utf8))
                                }
                            case .failed: self.finish(false)
                            default: break
                            }
                        }
                        client.start(queue: self.queue)
                    }
                    listener.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + 12) { self.finish(false) }
                } catch { self.finish(false) }
            }
        }
    }
    func finish(_ value: Bool) {
        guard !finished else { return }
        finished = true
        client?.cancel(); server?.cancel(); listener?.cancel()
        completion?.resume(returning: value); completion = nil
    }
}

@main struct SecureTransportChecks {
    static func main() async throws {
        let a = Data(repeating: 1, count: 32), b = Data(repeating: 2, count: 32)
        let keys = ["phone-a": a, "phone-b": b]
        guard await Probe().run(identity: "phone-a", secret: a, accepted: keys) else { fatalError("First registered PSK failed") }
        guard await Probe().run(identity: "phone-b", secret: b, accepted: keys) else { fatalError("Second registered PSK failed") }
        guard !(await Probe().run(identity: "phone-a", secret: b, accepted: keys)) else { fatalError("Wrong secret accepted") }
        guard !(await Probe().run(identity: "unknown", secret: a, accepted: keys)) else { fatalError("Unknown identity accepted") }
        let address = try RemoteAddress("[fd7a:115c:a1e0::1]:52418")
        precondition(address.host == "fd7a:115c:a1e0::1" && address.port == 52418)
        for bad in ["", "host:0", "host:70000", "https://host", "host/path", "user@host", "host?x"] {
            do { _ = try RemoteAddress(bad); fatalError("Bad address accepted: \(bad)") } catch {}
        }
        print("Secure transport: two identities, wrong keys, unknown peers, and address parsing passed")
    }
}
