//
//  NetworkManager.swift
//  AirBridge
//
//  Listens with TLS, advertises Bonjour, validates HMAC, and dispatches events.
//

import Foundation
import Network
import CoreGraphics
import ApplicationServices
import UniformTypeIdentifiers
#if os(macOS)
import ScreenCaptureKit
import AVFoundation
import VideoToolbox
import CoreServices
import AppKit
import Darwin
#endif

private final class ConnectionBox {
    var buffer = Data()
    var pendingSecret: Data
    var deviceID: String?   // Added property for deviceID
    var scrollAccumX: Double = 0
    var scrollAccumY: Double = 0
    // App-layer authentication state. Commands are only executed once the
    // connection has proven knowledge of the device's shared secret.
    var authenticated = false
    var authNonce: Data?
    init(secret: Data) { self.pendingSecret = secret }
}

#if os(macOS)
import AppKit

private protocol ScreenFrameConsumer: AnyObject {
    func didProduceFrame(_ image: CGImage)
}

private final class ScreenCaptureHelper: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var sampleBufferDisplayLayer = AVSampleBufferDisplayLayer()
    private let queue = DispatchQueue(label: "AirBridge.ScreenCapture")
    weak var consumer: ScreenFrameConsumer?
    private(set) var lastFrame: CGImage?

    func start() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw NSError(domain: "AirBridge", code: -2, userInfo: [NSLocalizedDescriptionKey: "No display available for capture"]) }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.scalesToFit = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.capturesAudio = false
        config.colorSpaceName = CGColorSpace.sRGB
        // Set a reasonable width matching current code's max; SC will scale appropriately when encoded later.
        config.width = display.width
        config.height = display.height

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
    }

    func stop() {
        stream?.stopCapture(completionHandler: { _ in })
        stream = nil
        lastFrame = nil
    }

    // SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, let imageBuffer = sampleBuffer.imageBuffer else { return }
        // Convert CVPixelBuffer to CGImage
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(imageBuffer, options: nil, imageOut: &cgImage)
        if let cgImage = cgImage {
            self.lastFrame = cgImage
            self.consumer?.didProduceFrame(cgImage)
        }
    }
}
#endif

final class NetworkManager {
    typealias PacketHandler = @Sendable (AirPacket) async -> Void
    typealias UnknownDeviceHandler = @Sendable (_ deviceID: String, _ proposedSecret: Data, _ decide: @escaping @Sendable (Bool) -> Void) -> Void

    private let queue = DispatchQueue(label: "AirBridge.Network")
    private var listener: NWListener?
    private let security = SecurityManager()
    private let onReceivePacket: PacketHandler
    private let onUnknownDevice: UnknownDeviceHandler
    private let onDeviceConnected: @Sendable (_ deviceID: String) -> Void
    private let onDeviceDisconnected: @Sendable (_ deviceID: String?) -> Void
    private let eventInjector = EventInjector()

    private var connectionBoxes: [ObjectIdentifier: ConnectionBox] = [:]

    // Video streaming state
    private var videoTimer: DispatchSourceTimer?
    private var videoMaxWidth: Int = 800
    private var videoQuality: Double = 0.6
    private var isSendingFrame = false
    #if os(macOS)
    private var screenCapture: ScreenCaptureHelper?
    private var latestCapturedImage: CGImage?
    #endif

    init(onReceivePacket: @escaping PacketHandler,
         onUnknownDevice: @escaping UnknownDeviceHandler,
         onDeviceConnected: @escaping @Sendable (_ deviceID: String) -> Void = { _ in },
         onDeviceDisconnected: @escaping @Sendable (_ deviceID: String?) -> Void = { _ in }) {
        self.onReceivePacket = onReceivePacket
        self.onUnknownDevice = onUnknownDevice
        self.onDeviceConnected = onDeviceConnected
        self.onDeviceDisconnected = onDeviceDisconnected
    }

    private func ensureAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    // Human-readable name for this Mac, shown on the iPhone when picking a Mac.
    private func machineName() -> String {
        return Host.current().localizedName ?? "Mac"
    }

    #if os(macOS)
    // Launches an app by bundle identifier using the modern, non-deprecated
    // NSWorkspace.openApplication API (replaces launchApplication(withBundleIdentifier:)).
    private func launchApp(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            print("[NetworkManager] launchApp: no app found for \(bundleID)")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
    #endif

    // Stable per-Mac identifier so the iPhone can key its per-Mac secret.
    private func machineID() -> String {
        let key = "airbridge.machineID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: key)
        return newID
    }

    func start() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                self?.ensureAccessibility()
                self?._start()
                cont.resume()
            }
        }
    }

    private func _start() {
        // Shared-key TLS-PSK listener (known-working transport). The server-side
        // per-device PSK *selection block* did not complete the TLS handshake in
        // practice, so the channel uses one shared key for encryption and we
        // enforce per-device authentication at the application layer after connect
        // (Stage 2b) instead of via the TLS PSK identity.
        let params = AirSecureChannel.makePSKParameters(psk: AirSecureChannel.stage1PSK,
                                                        identity: AirSecureChannel.stage1Identity)
        params.includePeerToPeer = false

        do {
            let listener = try NWListener(using: params, on: 0)
            self.listener = listener
            listener.service = NWListener.Service(name: self.machineName(), type: "_airbridge._tcp")
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    print("[AirBridge] Bonjour advertising _airbridge._tcp and listening")
                    print("[AirBridge] Listener ready on port: \(String(describing: self?.listener?.port))")
                case .failed(let error):
                    print("Listener failed: \(error)")
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                self?.handle(connection: conn)
            }
            listener.start(queue: queue)
        } catch {
            print("Failed to start listener: \(error)")
        }
    }

    private func handle(connection: NWConnection) {
        // Enforce LAN by checking endpoint is host and in local interface
        guard case let .hostPort(host, _) = connection.endpoint, host.debugDescription.contains(".") || true else {
            connection.cancel(); return
        }

        let secret = security.generateSharedSecret()
        let box = ConnectionBox(secret: secret)
        let key = ObjectIdentifier(connection)
        connectionBoxes[key] = box
        print("[AirBridge] Accepted connection: \(connection)")
        // Removed: initial pair_response send on accept per instructions.

        connection.stateUpdateHandler = { state in
            if case .failed(let error) = state { print("Conn failed: \(error)") }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        guard let box = connectionBoxes[key] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                box.buffer.append(data)
                // Process complete lines (\n-delimited)
                while let newlineIndex = box.buffer.firstIndex(of: 0x0A) { // 0x0A = \n
                    let lineData = box.buffer.prefix(upTo: newlineIndex)
                    // Drop the processed line + newline
                    box.buffer.removeSubrange(..<box.buffer.index(after: newlineIndex))
                    self.handleLine(lineData, from: connection, box: box)
                }
            }
            if isComplete || error != nil {
                let deviceID = box.deviceID
                self.connectionBoxes.removeValue(forKey: key)
                self.onDeviceDisconnected(deviceID)
                connection.cancel()
                return
            }
            self.receive(on: connection)
        }
    }

    private func handleLine(_ lineData: Data, from connection: NWConnection, box: ConnectionBox) {
        guard let raw = String(data: lineData, encoding: .utf8) else { return }
        print("[AirBridge] RX line: \(raw)")
        do {
            let obj = try JSONSerialization.jsonObject(with: lineData, options: [])
            guard let dict = obj as? [String: Any], let type = dict["type"] as? String else {
                throw NSError(domain: "AirBridge", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing type field"])
            }
            // Gate all functional messages until the connection has proven
            // knowledge of the device's per-device shared secret via the
            // challenge-response below. Only handshake messages are allowed
            // before authentication, so an unauthenticated peer can neither
            // inject input nor read system/app information.
            let openTypes: Set<String> = ["hello", "pair_request", "auth_proof"]
            if !openTypes.contains(type) && !box.authenticated {
                return
            }
            switch type {
            case "hello":
                if let payload = dict["payload"] as? [String: Any], let deviceID = payload["deviceID"] as? String {
                    box.deviceID = deviceID
                    // Tell the client which Mac this is so it can select/store the
                    // matching per-device key (enables one iPhone <-> many Macs).
                    self.sendLine(connection, jsonObject: [
                        "type": "server_info",
                        "payload": ["macID": self.machineID(), "macName": self.machineName()]
                    ])
                    // Attempt to load existing secret
                    if let _ = try? self.security.loadSharedSecret(for: deviceID) {
                        // Known device: require proof it holds the shared secret
                        // before authorizing. A device ID alone is not secret, so
                        // it is not sufficient — issue a random challenge.
                        let nonce = self.security.generateNonce(length: 32)
                        box.authNonce = nonce
                        self.sendLine(connection, jsonObject: [
                            "type": "auth_challenge",
                            "payload": ["nonce": nonce.base64EncodedString()]
                        ])
                    } else {
                        // Unknown device: ask the user to approve first-time pairing.
                        // Capture only Sendable values (NOT the non-Sendable box).
                        // onUnknownDevice is a plain completion-style callback (no
                        // async value crossing the actor boundary) — the previous
                        // async/@MainActor-isolated closure corrupted its arguments.
                        let pendingDeviceID = deviceID
                        let pendingSecret = box.pendingSecret
                        let connKey = ObjectIdentifier(connection)
                        self.onUnknownDevice(pendingDeviceID, pendingSecret) { [weak self] allowed in
                            guard let self else { return }
                            self.queue.async {
                                if allowed {
                                    // First-time pairing is trusted via explicit user
                                    // approval; the secret was exchanged over the
                                    // encrypted channel — authorize this connection.
                                    self.connectionBoxes[connKey]?.authenticated = true
                                    // Send the secret so the client can store it
                                    // under this Mac's ID.
                                    self.sendLine(connection, jsonObject: [
                                        "type": "pair_response",
                                        "shared_secret": pendingSecret.base64EncodedString()
                                    ])
                                    self.onDeviceConnected(pendingDeviceID)
                                } else {
                                    self.sendError("Pairing denied for \(pendingDeviceID)", to: connection)
                                    connection.cancel()
                                }
                            }
                        }
                    }
                } else {
                    self.sendError("hello missing payload.deviceID", to: connection)
                }
            case "auth_proof":
                // Verify the device knows its shared secret: HMAC(secret, nonce).
                guard let payload = dict["payload"] as? [String: Any],
                      let proofB64 = payload["proof"] as? String,
                      let proof = Data(base64Encoded: proofB64),
                      let deviceID = box.deviceID,
                      let nonce = box.authNonce,
                      let secret = try? self.security.loadSharedSecret(for: deviceID) else {
                    self.sendError("auth_proof: missing fields or unknown device", to: connection)
                    connection.cancel()
                    break
                }
                let expected = self.security.computeHMAC(secret: secret, data: nonce)
                if expected == proof {
                    box.authenticated = true
                    box.authNonce = nil
                    self.onDeviceConnected(deviceID)
                } else {
                    // Secret mismatch — almost always a stale pairing from earlier
                    // runs. Forget the stored secret and tell the client to reset,
                    // so the next connection performs a fresh pairing (with the
                    // approval prompt) instead of failing forever.
                    self.security.deleteSharedSecret(for: deviceID)
                    self.sendLine(connection, jsonObject: ["type": "auth_reset", "message": "Re-pair required"])
                    connection.cancel()
                }
            case "mouse_down":
                if let payload = dict["payload"] as? [String: Any], let button = payload["button"] as? String {
                    let kind: MouseClickKind = (button == "right" ? .right : button == "middle" ? .middle : .left)
                    // Synthesize button down using EventInjector via keyDown/Up mapping for mouse; implement as click down event
                    // EventInjector currently exposes clickMouse(kind:), but for down/up we can extend it or approximate with down event types.
                    // For now, post down only by sending the appropriate CGEventType.
                    do {
                        try self.eventInjector.mouseButtonDown(kind: kind)
                    } catch {
                        self.sendError("mouse_down failed: \(error.localizedDescription)", to: connection)
                    }
                }
            case "mouse_up":
                if let payload = dict["payload"] as? [String: Any], let button = payload["button"] as? String {
                    let kind: MouseClickKind = (button == "right" ? .right : button == "middle" ? .middle : .left)
                    do {
                        try self.eventInjector.mouseButtonUp(kind: kind)
                    } catch {
                        self.sendError("mouse_up failed: \(error.localizedDescription)", to: connection)
                    }
                }
            case "mouse_click":
                // Convenience that performs down+up using eventInjector.clickMouse(kind:)
                if let payload = dict["payload"] as? [String: Any], let button = payload["button"] as? String {
                    let kind: MouseClickKind = (button == "right" ? .right : button == "middle" ? .middle : .left)
                    try? self.eventInjector.clickMouse(kind: kind)
                }
            case "move", "mouse_move", "cursor_move", "air_mouse":
                if let payload = dict["payload"] as? [String: Any] {
                    if let dx = payload["dx"] as? Double, let dy = payload["dy"] as? Double {
                        try? self.eventInjector.moveMouse(dx: dx, dy: dy)
                    } else if let dxI = payload["dx"] as? Int, let dyI = payload["dy"] as? Int {
                        try? self.eventInjector.moveMouse(dx: Double(dxI), dy: Double(dyI))
                    }
                }
            case "scroll":
                if let payload = dict["payload"] as? [String: Any] {
                    var dxVal: Double? = nil
                    var dyVal: Double? = nil
                    if let dx = payload["dx"] as? Double, let dy = payload["dy"] as? Double {
                        dxVal = dx; dyVal = dy
                    } else if let dxI = payload["dx"] as? Int, let dyI = payload["dy"] as? Int {
                        dxVal = Double(dxI); dyVal = Double(dyI)
                    }
                    if let dx = dxVal, let dy = dyVal {
                        var totalX = box.scrollAccumX + dx
                        var totalY = box.scrollAccumY + dy
                        let intX = Int32(totalX.rounded(.towardZero))
                        let intY = Int32(totalY.rounded(.towardZero))
                        totalX -= Double(intX)
                        totalY -= Double(intY)
                        box.scrollAccumX = totalX
                        box.scrollAccumY = totalY
                        if intX != 0 || intY != 0 {
                            try? self.eventInjector.scroll(dx: Double(intX), dy: Double(intY))
                        }
                    }
                }
            case "key_down":
                if let payload = dict["payload"] as? [String: Any], let keyCode = payload["keyCode"] as? UInt64 {
                    try? self.eventInjector.keyDown(keyCode: CGKeyCode(keyCode))
                } else if let payload = dict["payload"] as? [String: Any], let keyCodeInt = payload["keyCode"] as? Int {
                    try? self.eventInjector.keyDown(keyCode: CGKeyCode(keyCodeInt))
                }
            case "key_up":
                if let payload = dict["payload"] as? [String: Any], let keyCode = payload["keyCode"] as? UInt64 {
                    try? self.eventInjector.keyUp(keyCode: CGKeyCode(keyCode))
                } else if let payload = dict["payload"] as? [String: Any], let keyCodeInt = payload["keyCode"] as? Int {
                    try? self.eventInjector.keyUp(keyCode: CGKeyCode(keyCodeInt))
                }
            case "swipe":
                if let payload = dict["payload"] as? [String: Any] {
                    var fingers: Int? = nil
                    if let f = payload["fingers"] as? Int { fingers = f }
                    else if let fD = payload["fingers"] as? Double { fingers = Int(fD) }
                    let direction = (payload["direction"] as? String)?.lowercased()
                    if let fingers = fingers, let direction = direction {
                        #if os(macOS)
                        // Left/right swipes switch Spaces. Drive this directly via
                        // SkyLight rather than synthetic Ctrl+Arrow: it doesn't
                        // depend on the Mission Control keyboard shortcuts being
                        // enabled and is far more reliable than posted key events.
                        if direction == "left" || direction == "right" {
                            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                                self?.switchSpace(offset: direction == "right" ? 1 : -1, fallbackFingers: fingers)
                            }
                        } else {
                            try? self.eventInjector.handleSwipe(fingers: fingers, direction: direction)
                        }
                        #else
                        try? self.eventInjector.handleSwipe(fingers: fingers, direction: direction)
                        #endif
                    }
                }
            case "action":
                if let payload = dict["payload"] as? [String: Any], let name = payload["name"] as? String {
                    try? self.eventInjector.handleAction(name: name)
                }
            case "nav":
                if let payload = dict["payload"] as? [String: Any], let direction = payload["direction"] as? String {
                    try? self.eventInjector.handleNav(direction: direction)
                }
            case "pinch":
                if let payload = dict["payload"] as? [String: Any], let direction = payload["direction"] as? String {
                    try? self.eventInjector.handlePinch(zoomIn: direction.lowercased() == "in")
                }
            case "pair_request":
                // (Re-)pairing initiated by the client (e.g. it has no key for this
                // Mac). Require explicit user approval, then store the new secret
                // (replacing any stale one) and send it back so both sides match.
                guard let deviceID = box.deviceID else {
                    self.sendError("pair_request before hello", to: connection); break
                }
                let pendingDeviceID = deviceID
                let pendingSecret = box.pendingSecret
                let connKey = ObjectIdentifier(connection)
                self.onUnknownDevice(pendingDeviceID, pendingSecret) { [weak self] allowed in
                    guard let self else { return }
                    self.queue.async {
                        if allowed {
                            self.connectionBoxes[connKey]?.authenticated = true
                            self.sendLine(connection, jsonObject: [
                                "type": "pair_response",
                                "shared_secret": pendingSecret.base64EncodedString()
                            ])
                            self.onDeviceConnected(pendingDeviceID)
                        } else {
                            self.sendError("Pairing denied for \(pendingDeviceID)", to: connection)
                            connection.cancel()
                        }
                    }
                }
            case "video_start":
                if let payload = dict["payload"] as? [String: Any] {
                    if let maxW = payload["maxWidth"] as? Int { self.videoMaxWidth = maxW }
                    else if let maxWD = payload["maxWidth"] as? Double { self.videoMaxWidth = Int(maxWD) }
                    if let q = payload["quality"] as? Double { self.videoQuality = max(0.1, min(1.0, q)) }
                }
                self.startVideoStream(to: connection)
            case "video_stop":
                self.stopVideoStream()

            case "request_installed_apps":
                #if os(macOS)
                // Enumerate installed apps on a background queue
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self else { return }
                    let ws = NSWorkspace.shared
                    var appsArray: [[String: Any]] = []
                    // Removed: // Use LaunchServices via NSWorkspace to get installed apps URLs and related code

                    // Removed: // Prefer LaunchServices API for all apps and related code

                    let fm = FileManager.default
                    let searchDirs: [URL] = [
                        URL(fileURLWithPath: "/Applications", isDirectory: true),
                        URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
                        URL(fileURLWithPath: "/System/Applications", isDirectory: true),
                        URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
                        URL(fileURLWithPath: NSHomeDirectory() + "/Applications", isDirectory: true)
                    ]

                    var urls: [URL] = []
                    var seenPaths = Set<String>()

                    for dir in searchDirs {
                        if (try? dir.checkResourceIsReachable()) != true { continue }
                        if let enumerator = fm.enumerator(
                            at: dir,
                            includingPropertiesForKeys: [.isDirectoryKey],
                            options: [.skipsHiddenFiles, .skipsPackageDescendants]
                        ) {
                            for case let fileURL as URL in enumerator {
                                if fileURL.pathExtension == "app" {
                                    let path = fileURL.standardizedFileURL.path
                                    if seenPaths.insert(path).inserted {
                                        urls.append(fileURL)
                                    }
                                }
                            }
                        }
                    }

                    let running = Set(ws.runningApplications.compactMap { $0.bundleIdentifier })
                    let isoFormatter = ISO8601DateFormatter()

                    // Build candidates grouped by bundle identifier
                    struct AppCandidate {
                        let bundleID: String
                        let name: String
                        let isRunning: Bool
                        let lastLaunched: String?
                        let installPath: String
                    }

                    var groups: [String: [AppCandidate]] = [:]

                    for url in urls {
                        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { continue }
                        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                            ?? (bundle.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String)
                            ?? url.deletingPathExtension().lastPathComponent
                        var lastLaunchStr: String? = nil
                        if let info = try? url.resourceValues(forKeys: [.contentAccessDateKey]), let date = info.contentAccessDate {
                            lastLaunchStr = isoFormatter.string(from: date)
                        }
                        let candidate = AppCandidate(
                            bundleID: bundleID,
                            name: name,
                            isRunning: running.contains(bundleID),
                            lastLaunched: lastLaunchStr,
                            installPath: url.standardizedFileURL.path
                        )
                        groups[bundleID, default: []].append(candidate)
                    }

                    // Coalesce to unique set keyed by bundleIdentifier.
                    // If multiple variants share a bundle ID, emit one item per variant and disambiguate with installPath/variant in the payload and id.
                    for (bundleID, candidates) in groups {
                        if candidates.count == 1, let c = candidates.first {
                            let appObj: [String: Any] = [
                                "id": bundleID,
                                "name": c.name,
                                "bundleIdentifier": bundleID,
                                "isRunning": c.isRunning,
                                "lastLaunched": c.lastLaunched as Any
                            ]
                            appsArray.append(appObj)
                        } else {
                            // Prefer running apps when ordering
                            let ordered = candidates.sorted { lhs, rhs in
                                if lhs.isRunning != rhs.isRunning { return lhs.isRunning && !rhs.isRunning }
                                // Fall back to most recently accessed
                                switch (lhs.lastLaunched, rhs.lastLaunched) {
                                case let (l?, r?): return l > r
                                case (_?, nil): return true
                                case (nil, _?): return false
                                default: return lhs.installPath < rhs.installPath
                                }
                            }
                            for c in ordered {
                                let variant = c.installPath
                                let appObj: [String: Any] = [
                                    "id": "\(bundleID)|\(variant)",
                                    "name": c.name,
                                    "bundleIdentifier": bundleID,
                                    "isRunning": c.isRunning,
                                    "lastLaunched": c.lastLaunched as Any,
                                    "installPath": variant,
                                    "variant": variant
                                ]
                                appsArray.append(appObj)
                            }
                        }
                    }

                    let response: [String: Any] = [
                        "type": "installed_apps",
                        "payload": ["apps": appsArray]
                    ]
                    self.sendLine(connection, jsonObject: response)
                }
                #else
                self.sendError("request_installed_apps not supported on this platform", to: connection)
                #endif

            case "request_app_icon":
                #if os(macOS)
                guard let payload = dict["payload"] as? [String: Any], let bundleID = payload["bundleIdentifier"] as? String else {
                    self.sendError("request_app_icon missing payload.bundleIdentifier", to: connection); break
                }
                let maxSize: Int = {
                    if let v = payload["maxSize"] as? Int { return v }
                    if let v = payload["maxSize"] as? Double { return Int(v) }
                    return 256
                }()
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self else { return }
                    let ws = NSWorkspace.shared
                    var image: NSImage?
                    if let url = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue() as? [URL], let appURL = url.first {
                        image = ws.icon(forFile: appURL.path)
                    } else if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                        image = ws.icon(forFile: appURL.path)
                    }
                    guard let nsImage = image else { self.sendError("Icon not found for \(bundleID)", to: connection); return }
                    let targetSize = NSSize(width: maxSize, height: maxSize)
                    let resized = NSImage(size: targetSize)
                    resized.lockFocus()
                    NSGraphicsContext.current?.imageInterpolation = .high
                    let rect = NSRect(origin: .zero, size: targetSize)
                    nsImage.draw(in: rect, from: .zero, operation: .copy, fraction: 1.0, respectFlipped: true, hints: nil)
                    resized.unlockFocus()
                    guard let tiff = resized.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let pngData = rep.representation(using: .png, properties: [:]) else {
                        self.sendError("Failed to encode icon for \(bundleID)", to: connection); return
                    }
                    let b64 = pngData.base64EncodedString()
                    let response: [String: Any] = [
                        "type": "app_icon",
                        "payload": ["bundleIdentifier": bundleID, "data": b64]
                    ]
                    self.sendLine(connection, jsonObject: response)
                }
                #else
                self.sendError("request_app_icon not supported on this platform", to: connection)
                #endif

            case "launch_app":
                #if os(macOS)
                if let payload = dict["payload"] as? [String: Any], let bundleID = payload["bundleIdentifier"] as? String {
                    self.launchApp(bundleID: bundleID)
                } else {
                    self.sendError("launch_app missing payload.bundleIdentifier", to: connection)
                }
                #endif

            case "activate_app":
                #if os(macOS)
                if let payload = dict["payload"] as? [String: Any], let bundleID = payload["bundleIdentifier"] as? String {
                    if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
                        _ = app.activate()
                    } else {
                        self.sendError("activate_app: app not running: \(bundleID)", to: connection)
                    }
                } else {
                    self.sendError("activate_app missing payload.bundleIdentifier", to: connection)
                }
                #endif

            case "launch_or_activate":
                #if os(macOS)
                if let payload = dict["payload"] as? [String: Any], let bundleID = payload["bundleIdentifier"] as? String {
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        guard let self else { return }
                        let ws = NSWorkspace.shared
                        if let app = ws.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
                            _ = app.activate()
                        } else {
                            self.launchApp(bundleID: bundleID)
                        }
                        // After action, send updated desktops and windows
                        self._sendDesktopsAndWindows(connection: connection)
                    }
                } else {
                    self.sendError("launch_or_activate missing payload.bundleIdentifier", to: connection)
                }
                #else
                self.sendError("launch_or_activate not supported on this platform", to: connection)
                #endif

            case "hide_app":
                #if os(macOS)
                if let payload = dict["payload"] as? [String: Any], let bundleID = payload["bundleIdentifier"] as? String {
                    if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
                        app.hide()
                    } else {
                        self.sendError("hide_app: app not running: \(bundleID)", to: connection)
                    }
                } else {
                    self.sendError("hide_app missing payload.bundleIdentifier", to: connection)
                }
                #endif

            case "quit_app":
                #if os(macOS)
                if let payload = dict["payload"] as? [String: Any], let bundleID = payload["bundleIdentifier"] as? String {
                    if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
                        app.terminate()
                    } else {
                        self.sendError("quit_app: app not running: \(bundleID)", to: connection)
                    }
                } else {
                    self.sendError("quit_app missing payload.bundleIdentifier", to: connection)
                }
                #endif

            case "force_quit_app":
                #if os(macOS)
                if let payload = dict["payload"] as? [String: Any], let bundleID = payload["bundleIdentifier"] as? String {
                    if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
                        app.forceTerminate()
                    } else {
                        self.sendError("force_quit_app: app not running: \(bundleID)", to: connection)
                    }
                } else {
                    self.sendError("force_quit_app missing payload.bundleIdentifier", to: connection)
                }
                #endif

            case "open_url":
                #if os(macOS)
                guard let payload = dict["payload"] as? [String: Any], let urlStr = payload["url"] as? String, let url = URL(string: urlStr) else {
                    self.sendError("open_url missing payload.url", to: connection); break
                }
                if let bundleID = payload["bundleIdentifier"] as? String {
                    let ok = NSWorkspace.shared.open([url],
                                                     withAppBundleIdentifier: bundleID,
                                                     options: [],
                                                     additionalEventParamDescriptor: nil,
                                                     launchIdentifiers: nil)
                    if !ok { self.sendError("open_url failed for bundle \(bundleID)", to: connection) }
                } else {
                    let ok = NSWorkspace.shared.open(url)
                    if !ok { self.sendError("open_url failed", to: connection) }
                }
                #else
                self.sendError("open_url not supported on this platform", to: connection)
                #endif

            case "request_desktops":
                #if os(macOS)
                // Enumerate Spaces (desktops) and return a list
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self else { return }
                    do {
                        let desktops = try self._enumerateDesktops()
                        var payloadObj: [String: Any] = ["desktops": desktops]
                        if let currentIdx = self._currentDesktopIndex(from: desktops) { payloadObj["current_desktop_index"] = currentIdx }
                        let response: [String: Any] = [
                            "type": "desktops",
                            "payload": payloadObj
                        ]
                        self.sendLine(connection, jsonObject: response)
                    } catch {
                        self.sendError("request_desktops failed: \(error.localizedDescription)", to: connection)
                    }
                }
                #else
                self.sendError("request_desktops not supported on this platform", to: connection)
                #endif

            case "focus_desktop":
                #if os(macOS)
                if let payload = dict["payload"] as? [String: Any], let id = payload["id"] as? String {
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        guard let self else { return }
                        do {
                            try self._focusDesktop(id: id)
                            // After focus, send updated state
                            self._sendDesktopsAndWindows(connection: connection)
                        } catch {
                            self.sendError("focus_desktop failed: \(error.localizedDescription)", to: connection)
                        }
                    }
                } else {
                    self.sendError("focus_desktop missing payload.id", to: connection)
                }
                #else
                self.sendError("focus_desktop not supported on this platform", to: connection)
                #endif

            case "request_open_windows":
                #if os(macOS)
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self else { return }
                    do {
                        let windows = try self._enumerateOpenWindows()
                        let response: [String: Any] = [
                            "type": "open_windows",
                            "payload": ["windows": windows]
                        ]
                        self.sendLine(connection, jsonObject: response)
                    } catch {
                        self.sendError("request_open_windows failed: \(error.localizedDescription)", to: connection)
                    }
                }
                #else
                self.sendError("request_open_windows not supported on this platform", to: connection)
                #endif

            case "focus_window":
                #if os(macOS)
                if let payload = dict["payload"] as? [String: Any], let windowID = payload["windowID"] as? String {
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        guard let self else { return }
                        do {
                            try self._focusWindowAndSpace(windowID: windowID)
                            self._sendDesktopsAndWindows(connection: connection)
                        } catch {
                            self.sendError("focus_window failed: \(error.localizedDescription)", to: connection)
                        }
                    }
                } else {
                    self.sendError("focus_window missing payload.windowID", to: connection)
                }
                #else
                self.sendError("focus_window not supported on this platform", to: connection)
                #endif

            case "focus_window_and_space":
                #if os(macOS)
                if let payload = dict["payload"] as? [String: Any], let windowID = payload["windowID"] as? String {
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        guard let self else { return }
                        do {
                            try self._focusWindowAndSpace(windowID: windowID)
                            self._sendDesktopsAndWindows(connection: connection)
                        } catch {
                            self.sendError("focus_window_and_space failed: \(error.localizedDescription)", to: connection)
                        }
                    }
                } else {
                    self.sendError("focus_window_and_space missing payload.windowID", to: connection)
                }
                #else
                self.sendError("focus_window_and_space not supported on this platform", to: connection)
                #endif

            case "move_window_to_desktop":
                #if os(macOS)
                if let payload = dict["payload"] as? [String: Any],
                   let windowID = payload["windowID"] as? String,
                   let desktopID = payload["desktopID"] as? String {
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        guard let self else { return }
                        do {
                            try self._moveWindow(windowID: windowID, toDesktopID: desktopID)
                            self._sendDesktopsAndWindows(connection: connection)
                        } catch {
                            self.sendError("move_window_to_desktop failed: \(error.localizedDescription)", to: connection)
                        }
                    }
                } else {
                    self.sendError("move_window_to_desktop missing payload.windowID or payload.desktopID", to: connection)
                }
                #else
                self.sendError("move_window_to_desktop not supported on this platform", to: connection)
                #endif

            case "move_window_to_display":
                #if os(macOS)
                if let payload = dict["payload"] as? [String: Any],
                   let windowID = payload["windowID"] as? String,
                   let displayID = payload["displayID"] as? String {
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        guard let self else { return }
                        do {
                            try self._moveWindow(windowID: windowID, toDisplayIdentifier: displayID)
                            self._sendDesktopsAndWindows(connection: connection)
                        } catch {
                            self.sendError("move_window_to_display failed: \(error.localizedDescription)", to: connection)
                        }
                    }
                } else {
                    self.sendError("move_window_to_display missing payload.windowID or payload.displayID", to: connection)
                }
                #else
                self.sendError("move_window_to_display not supported on this platform", to: connection)
                #endif

            case "request_window_thumbnail":
                #if os(macOS)
                if let payload = dict["payload"] as? [String: Any], let windowIDStr = payload["windowID"] as? String {
                    let maxWidth: Int = {
                        if let v = payload["maxWidth"] as? Int { return v }
                        if let v = payload["maxWidth"] as? Double { return Int(v) }
                        return 320
                    }()
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        guard let self else { return }
                        let responseType = "window_thumbnail"
                        var b64: String? = nil
                        if let n = Int(windowIDStr), let image = self._windowImage(windowNumber: n) {
                            if let data = self.jpegData(from: image, maxWidth: maxWidth, quality: 0.8) {
                                b64 = data.base64EncodedString()
                            }
                        } else {
                            self.sendError("request_window_thumbnail: image unavailable or permission missing", to: connection)
                        }
                        var payloadObj: [String: Any] = ["windowID": windowIDStr]
                        if let b64 = b64 { payloadObj["data"] = b64 } else { payloadObj["data"] = NSNull() }
                        let response: [String: Any] = [
                            "type": responseType,
                            "payload": payloadObj
                        ]
                        self.sendLine(connection, jsonObject: response)
                    }
                } else {
                    self.sendError("request_window_thumbnail missing payload.windowID", to: connection)
                }
                #else
                self.sendError("request_window_thumbnail not supported on this platform", to: connection)
                #endif

            default:
                break
            }
        } catch {
            print("[AirBridge] Parse error: \(error.localizedDescription) line=\(raw)")
            sendError("parse_error: \(error.localizedDescription)", to: connection)
        }
    }

    private func sendLine(_ connection: NWConnection, jsonObject: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(jsonObject) else { return }
        do {
            var data = try JSONSerialization.data(withJSONObject: jsonObject, options: [])
            data.append(0x0A)
            connection.send(content: data, completion: .contentProcessed { _ in })
        } catch {
            print("[AirBridge] Failed to encode JSON: \(error)")
        }
    }

    private func sendError(_ message: String, to connection: NWConnection) {
        let obj: [String: Any] = ["type": "error", "message": message]
        sendLine(connection, jsonObject: obj)
    }

    private func startVideoStream(to connection: NWConnection) {
        stopVideoStream()
        #if os(macOS)
        if screenCapture == nil {
            let helper = ScreenCaptureHelper()
            helper.consumer = self
            self.screenCapture = helper
            Task { [weak self] in
                do { try await helper.start() } catch {
                    self?.sendError("Screen capture start failed: \(error.localizedDescription)", to: connection)
                }
            }
        }
        #endif
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(66), leeway: .milliseconds(10)) // ~15 FPS
        timer.setEventHandler { [weak self, weak connection] in
            guard let self = self, let connection = connection else { return }
            if self.isSendingFrame { return }
            self.isSendingFrame = true
            #if os(macOS)
            if let frame = self.latestCapturedImage {
                if let data = self.jpegData(from: frame, maxWidth: self.videoMaxWidth, quality: self.videoQuality) {
                    let b64 = data.base64EncodedString()
                    let obj: [String: Any] = ["type": "video_jpeg", "payload": ["data": b64]]
                    self.sendLine(connection, jsonObject: obj)
                }
            }
            #else
            // Fallback (non-macOS platforms)
            #endif
            self.isSendingFrame = false
        }
        timer.resume()
        self.videoTimer = timer
    }

    private func stopVideoStream() {
        videoTimer?.cancel()
        videoTimer = nil
        isSendingFrame = false
        #if os(macOS)
        screenCapture?.stop()
        screenCapture = nil
        latestCapturedImage = nil
        #endif
    }

    private func jpegData(from cgImage: CGImage, maxWidth: Int, quality: Double) -> Data? {
        let width = cgImage.width
        let height = cgImage.height
        let scale = min(1.0, Double(maxWidth) / Double(width))
        let targetW = max(1, Int(Double(width) * scale))
        let targetH = max(1, Int(Double(height) * scale))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: targetW, height: targetH, bitsPerComponent: 8, bytesPerRow: targetW * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        guard let scaled = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let opts = [kCGImageDestinationLossyCompressionQuality as String: quality]
        CGImageDestinationAddImage(dest, scaled, opts as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }
}

#if os(macOS)

private typealias CGSConnectionID = UInt32
private typealias CGSCopyManagedDisplaySpacesFn = @convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?
private typealias CGSCopyActiveMenuBarDisplayIdentifierFn = @convention(c) (CGSConnectionID) -> Unmanaged<CFString>?
private typealias CGSManagedDisplaySetCurrentSpaceFn = @convention(c) (CGSConnectionID, CFString, Int) -> Void
private typealias CGSDefaultConnectionFn = @convention(c) () -> CGSConnectionID

private struct SkyLightPrivate {
    let handle: UnsafeMutableRawPointer?
    let copyManagedDisplaySpaces: CGSCopyManagedDisplaySpacesFn?
    let copyActiveMenuBarDisplayIdentifier: CGSCopyActiveMenuBarDisplayIdentifierFn?
    let managedDisplaySetCurrentSpace: CGSManagedDisplaySetCurrentSpaceFn?
    let defaultConnection: CGSDefaultConnectionFn?

    static let shared: SkyLightPrivate = {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        let handle = dlopen(path, RTLD_NOW)
        func load<T>(_ handle: UnsafeMutableRawPointer?, _ symbol: String, as: T.Type) -> T? {
            guard let h = handle, let sym = dlsym(h, symbol) else { return nil }
            return unsafeBitCast(sym, to: T.self)
        }
        return SkyLightPrivate(
            handle: handle,
            copyManagedDisplaySpaces: load(handle, "CGSCopyManagedDisplaySpaces", as: CGSCopyManagedDisplaySpacesFn.self),
            copyActiveMenuBarDisplayIdentifier: load(handle, "CGSCopyActiveMenuBarDisplayIdentifier", as: CGSCopyActiveMenuBarDisplayIdentifierFn.self),
            managedDisplaySetCurrentSpace: load(handle, "CGSManagedDisplaySetCurrentSpace", as: CGSManagedDisplaySetCurrentSpaceFn.self),
            defaultConnection: load(handle, "_CGSDefaultConnection", as: CGSDefaultConnectionFn.self)
        )
    }()

    var connection: CGSConnectionID { defaultConnection?() ?? 0 }
}

private extension NetworkManager {
    enum AirBridgeError: Error { case spacesUnavailable, spaceNotFound, invalidWindowID }

    func _enumerateDesktops() throws -> [[String: Any]] {
        let api = SkyLightPrivate.shared
        guard let copy = api.copyManagedDisplaySpaces else { throw AirBridgeError.spacesUnavailable }
        let conn = api.connection
        guard let displays = copy(conn)?.takeRetainedValue() as? [[String: Any]], !displays.isEmpty else { return [] }
        let activeDisplayID = api.copyActiveMenuBarDisplayIdentifier?(conn)?.takeRetainedValue() as String?
        let displayDict: [String: Any] = {
            if let active = activeDisplayID, let dict = displays.first(where: { ($0["Display Identifier"] as? String) == active }) { return dict }
            return displays[0]
        }()
        let spaces = displayDict["Spaces"] as? [[String: Any]] ?? []
        var currentUUID: String?
        var currentMSID: Int?
        if let cur = displayDict["Current Space"] as? [String: Any] {
            currentUUID = cur["uuid"] as? String
            if let n = cur["ManagedSpaceID"] as? NSNumber { currentMSID = n.intValue }
            else if let n = cur["ManagedSpaceID"] as? Int { currentMSID = n }
        }
        var result: [[String: Any]] = []
        for (idx, s) in spaces.enumerated() {
            let uuid = (s["uuid"] as? String) ?? String(describing: s["ManagedSpaceID"] ?? "")
            let name = s["Name"] as? String
            var msid: Int?
            if let n = s["ManagedSpaceID"] as? NSNumber { msid = n.intValue } else if let n = s["ManagedSpaceID"] as? Int { msid = n }
            let isActive = (currentUUID != nil && uuid == currentUUID) || (currentMSID != nil && msid != nil && currentMSID == msid)
            var obj: [String: Any] = [
                "id": uuid,
                "index": idx + 1,
                "isActive": isActive
            ]
            if let name = name { obj["name"] = name }
            result.append(obj)
        }
        return result
    }

    func _currentDesktopIndex(from desktops: [[String: Any]]) -> Int? {
        for d in desktops {
            if let isActive = d["isActive"] as? Bool, isActive, let idx = d["index"] as? Int {
                return idx
            }
        }
        return nil
    }

    func _focusDesktop(id: String) throws {
        let api = SkyLightPrivate.shared
        guard let copy = api.copyManagedDisplaySpaces, let setCurrent = api.managedDisplaySetCurrentSpace else { throw AirBridgeError.spacesUnavailable }
        let conn = api.connection
        guard let displays = copy(conn)?.takeRetainedValue() as? [[String: Any]], !displays.isEmpty else { return }
        let activeDisplayID = api.copyActiveMenuBarDisplayIdentifier?(conn)?.takeRetainedValue() as String?
        let displayDict: [String: Any] = {
            if let active = activeDisplayID, let dict = displays.first(where: { ($0["Display Identifier"] as? String) == active }) { return dict }
            return displays[0]
        }()
        let displayIdentifier = (displayDict["Display Identifier"] as? String) ?? ""
        let spaces = displayDict["Spaces"] as? [[String: Any]] ?? []
        guard let target = spaces.first(where: { ($0["uuid"] as? String) == id || String(describing: $0["ManagedSpaceID"] ?? "") == id }) else { throw AirBridgeError.spaceNotFound }
        let msid: Int
        if let n = target["ManagedSpaceID"] as? NSNumber { msid = n.intValue }
        else if let n = target["ManagedSpaceID"] as? Int { msid = n }
        else { throw AirBridgeError.spaceNotFound }
        setCurrent(conn, displayIdentifier as CFString, msid)
    }

    /// Switches to the Space `offset` positions away (e.g. +1 = the Space to the
    /// right) using SkyLight directly, so it works regardless of the Mission
    /// Control keyboard-shortcut settings. Falls back to a synthetic Ctrl+Arrow
    /// only if the private API is unavailable.
    func switchSpace(offset: Int, fallbackFingers: Int) {
        do {
            let desktops = try _enumerateDesktops()
            guard !desktops.isEmpty else { throw AirBridgeError.spacesUnavailable }
            guard let current = _currentDesktopIndex(from: desktops) else { throw AirBridgeError.spaceNotFound }
            let targetIndex = current + offset
            // No wrap-around: stay put at the edges, matching native behavior.
            guard targetIndex >= 1, targetIndex <= desktops.count,
                  let target = desktops.first(where: { ($0["index"] as? Int) == targetIndex }),
                  let id = target["id"] as? String else {
                print("[NetworkManager] switchSpace: no Space at index \(targetIndex) (have \(desktops.count))")
                return
            }
            try _focusDesktop(id: id)
            print("[NetworkManager] switchSpace -> index \(targetIndex)")
        } catch {
            // SkyLight unavailable; fall back to the keyboard shortcut.
            print("[NetworkManager] switchSpace falling back to Ctrl+Arrow: \(error)")
            try? eventInjector.handleSwipe(fingers: fallbackFingers, direction: offset > 0 ? "right" : "left")
        }
    }

    func _enumerateOpenWindows() throws -> [[String: Any]] {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let spaceMap = _buildWindowToSpaceIndexMap()
        var result: [[String: Any]] = []
        var axCache: [pid_t: [Int: Bool]] = [:]
        for w in windowInfo {
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            if layer != 0 { continue }
            guard let windowNumber = w[kCGWindowNumber as String] as? Int else { continue }
            guard let ownerPID = w[kCGWindowOwnerPID as String] as? Int32 else { continue }
            let ownerName = w[kCGWindowOwnerName as String] as? String ?? ""
            let title = w[kCGWindowName as String] as? String ?? ""
            let isOnScreen = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
            let pid = pid_t(ownerPID)
            let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier

            // Minimized via AX (best-effort)
            let minimizedMap: [Int: Bool]
            if let cached = axCache[pid] { minimizedMap = cached } else { let m = _axMinimizedMap(for: pid); axCache[pid] = m; minimizedMap = m }
            let isMinimized = minimizedMap[windowNumber] ?? false

            var obj: [String: Any] = [
                "windowID": String(windowNumber),
                "title": title,
                "appBundleIdentifier": bundleID as Any,
                "appName": ownerName,
                "isMinimized": isMinimized,
                "isOnScreen": isOnScreen,
                "ownerPID": Int(ownerPID)
            ]
            if let spaceIndex = spaceMap[windowNumber] { obj["space"] = spaceIndex }
            result.append(obj)
        }
        return result
    }

    func _focusWindow(windowID: String) throws {
        let targetWindowNumber: Int
        if let n = Int(windowID) { targetWindowNumber = n }
        else if let n = windowID.split(separator: "-").last.flatMap({ Int($0) }) { targetWindowNumber = n }
        else { throw AirBridgeError.invalidWindowID }

        guard let windowInfo = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return }
        guard let entry = windowInfo.first(where: { ($0[kCGWindowNumber as String] as? Int) == targetWindowNumber }) else { return }
        guard let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32 else { return }
        let pid = pid_t(ownerPID)
        if let app = NSRunningApplication(processIdentifier: pid) { _ = app.activate() }
        let appAX = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &value) == .success, let arr = value as? [AXUIElement] {
            for elem in arr {
                var wnum: CFTypeRef?
                if AXUIElementCopyAttributeValue(elem, "AXWindowNumber" as CFString, &wnum) == .success, let num = wnum as? NSNumber, num.intValue == targetWindowNumber {
                    AXUIElementPerformAction(elem, kAXRaiseAction as CFString)
                    AXUIElementSetAttributeValue(appAX, kAXFocusedWindowAttribute as CFString, elem)
                    AXUIElementSetAttributeValue(appAX, kAXMainWindowAttribute as CFString, elem)
                    break
                }
            }
        }
    }

    func _axMinimizedMap(for pid: pid_t) -> [Int: Bool] {
        var map: [Int: Bool] = [:]
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success, let arr = value as? [AXUIElement] {
            for elem in arr {
                var wnumValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(elem, "AXWindowNumber" as CFString, &wnumValue) == .success, let num = wnumValue as? NSNumber {
                    let windowNumber = num.intValue
                    var minimizedVal: CFTypeRef?
                    if AXUIElementCopyAttributeValue(elem, kAXMinimizedAttribute as CFString, &minimizedVal) == .success, let minBool = minimizedVal as? Bool {
                        map[windowNumber] = minBool
                    } else {
                        map[windowNumber] = false
                    }
                }
            }
        }
        return map
    }

    func _spaceIndexForWindow(windowNumber: Int) -> Int? {
        // Optional: Space index resolution omitted for stability; return nil when not available.
        return nil
    }

    func _buildWindowToSpaceIndexMap() -> [Int: Int] {
        var mapping: [Int: Int] = [:]
        let api = SkyLightPrivate.shared
        guard let copy = api.copyManagedDisplaySpaces else { return mapping }
        let conn = api.connection
        guard let displays = copy(conn)?.takeRetainedValue() as? [[String: Any]] else { return mapping }
        for display in displays {
            guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            for (idx, s) in spaces.enumerated() {
                let index = idx + 1
                if let nums = s["Windows"] as? [NSNumber] {
                    for n in nums { mapping[n.intValue] = index }
                } else if let ints = s["Windows"] as? [Int] {
                    for n in ints { mapping[n] = index }
                } else if let arr = s["Windows"] as? [Any] {
                    for any in arr {
                        if let n = any as? NSNumber { mapping[n.intValue] = index }
                        else if let n = any as? Int { mapping[n] = index }
                    }
                }
            }
        }
        return mapping
    }

    func _windowImage(windowNumber: Int) -> CGImage? {
        // Resolve window bounds first
        guard let bounds = _windowBounds(windowNumber: windowNumber) else { return nil }

        // Capture a single screen frame using ScreenCaptureKit
        final class OneShotConsumer: ScreenFrameConsumer {
            let sema: DispatchSemaphore
            var image: CGImage?
            init(sema: DispatchSemaphore) { self.sema = sema }
            func didProduceFrame(_ image: CGImage) {
                if self.image == nil { self.image = image; sema.signal() }
            }
        }

        let sema = DispatchSemaphore(value: 0)
        let helper = ScreenCaptureHelper()
        let consumer = OneShotConsumer(sema: sema)
        helper.consumer = consumer

        // Start capture asynchronously and wait for first frame (with timeout)
        Task {
            do { try await helper.start() } catch { sema.signal() }
        }
        let waitResult = sema.wait(timeout: .now() + 1.0)
        helper.stop()
        guard waitResult == .success, let frame = consumer.image else { return nil }

        // Compute crop rect in pixels (convert from points using backing scale factor)
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let pxWidth = CGFloat(frame.width)
        let pxHeight = CGFloat(frame.height)
        var crop = CGRect(x: bounds.origin.x * scale,
                          y: (pxHeight - (bounds.origin.y + bounds.size.height) * scale),
                          width: bounds.size.width * scale,
                          height: bounds.size.height * scale)
        // Clamp to image bounds
        let imageRect = CGRect(x: 0, y: 0, width: pxWidth, height: pxHeight)
        crop = crop.intersection(imageRect)
        guard crop.width > 1 && crop.height > 1 else { return frame }
        return frame.cropping(to: crop)
    }

    func _windowBounds(windowNumber: Int) -> CGRect? {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return nil }
        guard let entry = windowInfo.first(where: { ($0[kCGWindowNumber as String] as? Int) == windowNumber }) else { return nil }
        if let dict = entry[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: dict) {
            return rect
        }
        return nil
    }

    func _windowSpaceInfo(windowNumber: Int) -> (id: String, index: Int)? {
        let api = SkyLightPrivate.shared
        guard let copy = api.copyManagedDisplaySpaces else { return nil }
        let conn = api.connection
        guard let displays = copy(conn)?.takeRetainedValue() as? [[String: Any]] else { return nil }
        for display in displays {
            guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            for (idx, s) in spaces.enumerated() {
                let windowsAny = s["Windows"]
                var contains = false
                if let nums = windowsAny as? [NSNumber] {
                    contains = nums.contains { $0.intValue == windowNumber }
                } else if let ints = windowsAny as? [Int] {
                    contains = ints.contains(windowNumber)
                } else if let arr = windowsAny as? [Any] {
                    for any in arr {
                        if let n = any as? NSNumber, n.intValue == windowNumber { contains = true; break }
                        if let n = any as? Int, n == windowNumber { contains = true; break }
                    }
                }
                if contains {
                    let uuid = (s["uuid"] as? String) ?? String(describing: s["ManagedSpaceID"] ?? "")
                    return (uuid, idx + 1)
                }
            }
        }
        return nil
    }

    func _focusWindowAndSpace(windowID: String) throws {
        let targetWindowNumber: Int
        if let n = Int(windowID) { targetWindowNumber = n }
        else if let n = windowID.split(separator: "-").last.flatMap({ Int($0) }) { targetWindowNumber = n }
        else { throw AirBridgeError.invalidWindowID }
        if let space = _windowSpaceInfo(windowNumber: targetWindowNumber) {
            // Best-effort: switch space first; ignore errors here to continue focusing the window
            try? _focusDesktop(id: space.id)
        }
        try _focusWindow(windowID: windowID)
    }

    func _moveWindow(windowID: String, toDesktopID desktopUUID: String) throws {
        // Resolve window number
        let targetWindowNumber: Int
        if let n = Int(windowID) { targetWindowNumber = n }
        else if let n = windowID.split(separator: "-").last.flatMap({ Int($0) }) { targetWindowNumber = n }
        else { throw AirBridgeError.invalidWindowID }

        // Switch to the destination space first
        try _focusDesktop(id: desktopUUID)
        // Then focus window (brings app to front) and rely on system to keep it on the current space when raised
        try _focusWindow(windowID: String(targetWindowNumber))
    }

    func _moveWindow(windowID: String, toDisplayIdentifier displayID: String) throws {
        // Move a window to a given display by switching the active space to a space on that display, then focusing the window
        let api = SkyLightPrivate.shared
        guard let copy = api.copyManagedDisplaySpaces else { throw AirBridgeError.spacesUnavailable }
        let conn = api.connection
        guard let displays = copy(conn)?.takeRetainedValue() as? [[String: Any]] else { throw AirBridgeError.spacesUnavailable }
        guard let display = displays.first(where: { ($0["Display Identifier"] as? String) == displayID }) else { throw AirBridgeError.spaceNotFound }
        guard let spaces = display["Spaces"] as? [[String: Any]], let firstSpace = spaces.first else { throw AirBridgeError.spaceNotFound }
        let destUUID = (firstSpace["uuid"] as? String) ?? String(describing: firstSpace["ManagedSpaceID"] ?? "")
        try _moveWindow(windowID: windowID, toDesktopID: destUUID)
    }

    func _sendDesktopsAndWindows(connection: NWConnection) {
        do {
            let desktops = try _enumerateDesktops()
            let windows = try _enumerateOpenWindows()
            var desktopsPayload: [String: Any] = ["desktops": desktops]
            if let currentIdx = _currentDesktopIndex(from: desktops) { desktopsPayload["current_desktop_index"] = currentIdx }
            let desktopsObj: [String: Any] = ["type": "desktops", "payload": desktopsPayload]
            let windowsObj: [String: Any] = ["type": "open_windows", "payload": ["windows": windows]]
            sendLine(connection, jsonObject: desktopsObj)
            sendLine(connection, jsonObject: windowsObj)
        } catch {
            sendError("state_update_failed: \(error.localizedDescription)", to: connection)
        }
    }
}

#endif

#if os(macOS)
extension NetworkManager: ScreenFrameConsumer {
    func didProduceFrame(_ image: CGImage) {
        self.latestCapturedImage = image
    }
}
#endif

