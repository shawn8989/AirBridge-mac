//
//  AppState.swift
//  AirBridge
//
//  Manages shared state, pairing prompts, and status messages.
//

import Foundation
import SwiftUI
import Combine
import ServiceManagement
import ApplicationServices
import UserNotifications

/// One row in the Activity feed.
struct ActivityEntry: Identifiable, Equatable {
    let id = UUID()
    let date = Date()
    let symbol: String
    let text: String
}

/// Delivers a pairing decision to everyone waiting on it, exactly once.
///
/// A CheckedContinuation traps the whole process if it is resumed twice, and
/// there are several ways that happened here: a second press of Allow before
/// the sheet finished dismissing, and a first connection that asks twice (the
/// phone sends `hello` with an unknown device ID *and* a `pair_request` when it
/// holds no key for this Mac), which put two continuations behind one prompt.
///
/// Just as bad was the opposite failure: a continuation that was never resumed
/// at all, because a second request overwrote `pendingPairRequest` and orphaned
/// the first. That connection then waited forever without ever being
/// authenticated — and since unauthenticated messages are dropped silently, the
/// phone showed "connected" while every command went in the bin.
///
/// Both stop being possible if "resume exactly once, and resume everyone" is a
/// property of this type rather than something each call site has to get right.
@MainActor
final class PairDecision {
    private var waiting: [CheckedContinuation<Bool, Never>] = []
    private var decision: Bool?

    var isDecided: Bool { decision != nil }

    func add(_ continuation: CheckedContinuation<Bool, Never>) {
        if let decision {
            continuation.resume(returning: decision)   // already answered
        } else {
            waiting.append(continuation)
        }
    }

    /// Returns false if a decision had already been delivered, so callers can
    /// tell a real answer from a duplicate.
    @discardableResult
    func resume(_ allowed: Bool) -> Bool {
        guard decision == nil else { return false }
        decision = allowed
        let pending = waiting
        waiting.removeAll()
        for continuation in pending { continuation.resume(returning: allowed) }
        return true
    }
}

/// Represents a first-time pairing request from an unknown device.
struct PairRequest: Identifiable {
    let id = UUID()
    let deviceID: String
    let proposedSecret: Data
    let decision: PairDecision
}

/// Represents a connected device and when it connected.
struct DeviceConnection: Identifiable, Equatable {
    let id: String   // deviceID
    let connectedAt: Date
}

@MainActor
final class AppState: ObservableObject {
    @Published var statusMessage: String = "Waiting for connections…"
    @Published var pendingPairRequest: PairRequest?
    @Published var connectedDevices: [DeviceConnection] = []

    private let securityManager = SecurityManager()
    private lazy var eventInjector = EventInjector()
    private var networkManager: NetworkManager!

    init() {
        // Single instance only: two AirBridges fight over the fixed port and
        // Bonjour registration, and both inject input — chaos. If another
        // instance is already running, bring it forward and bow out.
        let myPID = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? "com.airbridge"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID }
        if let existing = others.first {
            existing.activate()
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }

        networkManager = NetworkManager(
            onReceivePacket: { [weak self] packet in
                await self?.handle(packet: packet)
            },
            onUnknownDevice: { [weak self] deviceID, proposedSecret, decide in
                // Plain (non-async, non-isolated) callback that hops to the main
                // actor explicitly. Returning a value from an async @MainActor
                // closure here corrupted its arguments; this pattern matches the
                // other callbacks and is safe.
                Task { @MainActor in
                    guard let self else { decide(false); return }
                    let allowed = await self.promptPairing(deviceID: deviceID, proposedSecret: proposedSecret)
                    decide(allowed)
                }
            },
            onDeviceConnected: { [weak self] deviceID in
                Task { @MainActor in
                    guard let self else { return }
                    if !self.connectedDevices.contains(where: { $0.id == deviceID }) {
                        self.connectedDevices.append(DeviceConnection(id: deviceID, connectedAt: Date()))
                    }
                    let name = self.displayName(for: deviceID)
                    self.statusMessage = "Connected: \(name)"
                    self.logActivity("iphone.radiowaves.left.and.right", "\(name) connected")
                    self.notify("Wield connected", name)
                }
            },
            onDeviceDisconnected: { [weak self] deviceID in
                Task { @MainActor in
                    guard let self else { return }
                    if let id = deviceID {
                        self.connectedDevices.removeAll { $0.id == id }
                        let name = self.displayName(for: id)
                        self.statusMessage = "Disconnected: \(name)"
                        self.logActivity("iphone.slash", "\(name) disconnected")
                        self.notify("Wield disconnected", name)
                    } else {
                        self.statusMessage = "Disconnected"
                    }
                }
            }
        )
        networkManager.onQRPaired = { [weak self] deviceID in
            // Already hopped to main by NetworkManager.
            self?.qrPayload = nil
            self?.statusMessage = "Paired via QR: \(deviceID.prefix(8))…"
            self?.logActivity("qrcode", "Paired \(self?.displayName(for: deviceID) ?? "a device") via QR")
        }
        networkManager.onDeviceNamed = { [weak self] deviceID, name in
            guard let self else { return }
            // Reported names never override a user-chosen nickname.
            if self.nicknames[deviceID] == nil { self.deviceNames[deviceID] = name }
        }
        networkManager.onMetrics = { [weak self] perSecond, totals in
            guard let self else { return }
            self.eventsPerSecond = perSecond
            self.deviceEventTotals = totals
            self.recentRates.append(perSecond)
            if self.recentRates.count > 30 { self.recentRates.removeFirst(self.recentRates.count - 30) }
        }
        networkManager.onActivity = { [weak self] symbol, text in
            self?.logActivity(symbol, text)
        }
        startAccessibilityPolling()
        // Nested ObservableObjects don't propagate; forward the checker's
        // changes so the update banner appears without a view poke.
        updateCancellable = updateChecker.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        updateChecker.check()
        Task { await networkManager.start() }

        // If we quit with a synthetic modifier or mouse button still held,
        // it stays latched in the window server and the user's PHYSICAL
        // keyboard/mouse misbehave until reboot. Always release on exit.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.networkManager.emergencyReleaseInput()
            // Give the async release a beat to post before the process dies.
            Thread.sleep(forTimeInterval: 0.15)
        }
    }

    private var updateCancellable: AnyCancellable?

    // MARK: - Live metrics (dashboard)

    @Published var eventsPerSecond: Int = 0
    @Published var recentRates: [Int] = []
    @Published var deviceEventTotals: [String: Int] = [:]

    // MARK: - Device names & nicknames

    /// Names reported by devices (hello payload), persisted for offline display.
    @Published var deviceNames: [String: String] = UserDefaults.standard
        .dictionary(forKey: "airbridge.deviceNames") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(deviceNames, forKey: "airbridge.deviceNames") }
    }
    /// User-chosen overrides; win over reported names.
    @Published var nicknames: [String: String] = UserDefaults.standard
        .dictionary(forKey: "airbridge.nicknames") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(nicknames, forKey: "airbridge.nicknames") }
    }

    func displayName(for deviceID: String) -> String {
        nicknames[deviceID] ?? deviceNames[deviceID] ?? String(deviceID.prefix(8)) + "…"
    }

    func setNickname(_ name: String, for deviceID: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            nicknames.removeValue(forKey: deviceID)
        } else {
            nicknames[deviceID] = trimmed
        }
    }

    /// Every device we know a name for — drives the "previously paired" list.
    var knownDeviceIDs: [String] {
        Array(Set(deviceNames.keys).union(nicknames.keys)).sorted {
            displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending
        }
    }

    // MARK: - Activity log

    @Published var activity: [ActivityEntry] = []

    func logActivity(_ symbol: String, _ text: String) {
        activity.insert(ActivityEntry(symbol: symbol, text: text), at: 0)
        if activity.count > 100 { activity.removeLast(activity.count - 100) }
    }

    // MARK: - Notifications

    @Published var notifyOnConnect: Bool = UserDefaults.standard.object(forKey: "airbridge.notifyOnConnect") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "airbridge.notifyOnConnect") {
        didSet { UserDefaults.standard.set(notifyOnConnect, forKey: "airbridge.notifyOnConnect") }
    }
    private var notificationAuthRequested = false

    /// Posts a local notification — only when the app isn't frontmost, so it
    /// informs without nagging.
    func notify(_ title: String, _ body: String) {
        guard notifyOnConnect, !NSApp.isActive else { return }
        let center = UNUserNotificationCenter.current()
        let post = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        if notificationAuthRequested {
            post()
        } else {
            notificationAuthRequested = true
            center.requestAuthorization(options: [.alert]) { granted, _ in
                if granted { post() }
            }
        }
    }

    // MARK: - Server on/off

    @Published var serverEnabled = true {
        didSet {
            networkManager.setServerEnabled(serverEnabled)
            logActivity(serverEnabled ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash",
                        serverEnabled ? "Advertising resumed" : "Advertising stopped")
            if !serverEnabled { connectedDevices.removeAll() }
        }
    }

    // MARK: - Accessibility polling (live onboarding checklist)

    @Published var accessibilityOK = AXIsProcessTrusted()
    @Published var screenRecordingOK = CGPreflightScreenCaptureAccess()
    private var axTimer: Timer?

    private func startAccessibilityPolling() {
        axTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let ax = AXIsProcessTrusted()
                if ax != self.accessibilityOK { self.accessibilityOK = ax }
                let sr = CGPreflightScreenCaptureAccess()
                if sr != self.screenRecordingOK { self.screenRecordingOK = sr }
            }
        }
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Updates

    let updateChecker = UpdateChecker()

    // MARK: - QR pairing UI state

    /// JSON string currently displayed as a QR code (nil = window closed).
    @Published var qrPayload: String?

    func showPairingQR() {
        qrPayload = networkManager.beginQRPairing()
        // Auto-expire the display alongside the server-side 2-minute window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            if self?.qrPayload != nil { self?.hidePairingQR() }
        }
    }

    func hidePairingQR() {
        qrPayload = nil
        networkManager.cancelQRPairing()
    }

    func handle(packet: AirPacket) async {
        do {
            switch packet.type {
            case .mouseMove(let dx, let dy):
                try eventInjector.moveMouse(dx: dx, dy: dy)
            case .mouseClick(let kind):
                try eventInjector.clickMouse(kind: kind)
            case .scroll(let dx, let dy):
                try eventInjector.scroll(dx: dx, dy: dy)
            case .keyDown(let keyCode):
                try eventInjector.keyDown(keyCode: keyCode)
            case .keyUp(let keyCode):
                try eventInjector.keyUp(keyCode: keyCode)
            case .action(let name):
                // Map high-level actions (e.g., three_swipe_*) to control+arrow helpers
                try eventInjector.handleAction(name: name)
            case .swipe(let fingers, let direction):
                // Handle swipe gestures (e.g., three-finger swipes for Mission Control/App Exposé)
                try eventInjector.handleSwipe(fingers: fingers, direction: direction)
            default:
                // Ignore unhandled packet types to keep switch exhaustive
                break
            }
        } catch {
            statusMessage = "Event error: \(error.localizedDescription)"
        }
    }

    // MARK: - Controls (dashboard + menu bar)

    /// Suppresses input injection while leaving the connection healthy.
    @Published var inputPaused = false {
        didSet {
            networkManager.setInputPaused(inputPaused)
            logActivity(inputPaused ? "pause.circle" : "play.circle",
                        inputPaused ? "Input paused" : "Input resumed")
        }
    }

    var macName: String { Host.current().localizedName ?? "Mac" }
    var accessibilityGranted: Bool { AXIsProcessTrusted() }
    var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            statusMessage = "Launch at Login failed: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }

    /// Removes a device's pairing so its next connection requires re-approval.
    func forgetDevice(_ deviceID: String) {
        securityManager.deleteSharedSecret(for: deviceID)
        connectedDevices.removeAll { $0.id == deviceID }
        statusMessage = "Forgot device \(deviceID.prefix(8))…"
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func promptPairing(deviceID: String, proposedSecret: Data) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            if let pending = pendingPairRequest,
               pending.deviceID == deviceID,
               pending.proposedSecret == proposedSecret {
                // The same connection asking a second time: a first-time
                // connection sends `hello` with an unknown device ID and then a
                // `pair_request`, and both raise a prompt. Show one, and let a
                // single Allow answer everyone waiting behind it.
                pending.decision.add(continuation)
                return
            }
            if let stale = pendingPairRequest {
                // A different device (or a different connection from the same
                // one) is taking over the prompt. Deny the old request rather
                // than dropping it on the floor — an orphaned continuation
                // leaves its connection unauthenticated forever, and
                // unauthenticated messages are discarded without a word, so the
                // phone sits there looking connected and doing nothing.
                stale.decision.resume(false)
            }
            let decision = PairDecision()
            decision.add(continuation)
            pendingPairRequest = PairRequest(deviceID: deviceID,
                                             proposedSecret: proposedSecret,
                                             decision: decision)
        }
    }

    func handlePairingDecision(allowed: Bool, request: PairRequest) async {
        // A second press of Allow, or a decision for a request that was already
        // superseded, must not reach the continuation twice.
        guard !request.decision.isDecided else { return }

        // Persist BEFORE answering. Resuming first tells the phone it is paired
        // and lets it reconnect while this side still has no secret — which
        // lands it straight back on "unknown device", the loop that made
        // Forget-and-retry necessary. A Keychain failure has to deny, not
        // hand out a pairing this Mac cannot honour.
        var granted = allowed
        if allowed {
            do {
                try securityManager.storeSharedSecret(request.proposedSecret, for: request.deviceID)
            } catch {
                granted = false
                statusMessage = "Keychain error: \(error.localizedDescription)"
                logActivity("xmark.seal", "Pairing failed: \(error.localizedDescription)")
            }
        }

        guard request.decision.resume(granted) else { return }
        if pendingPairRequest?.id == request.id { pendingPairRequest = nil }
        if granted {
            statusMessage = "Paired with \(displayName(for: request.deviceID))"
            logActivity("checkmark.seal", "Paired \(displayName(for: request.deviceID))")
        } else if allowed {
            // Denied only because the Keychain write failed; already logged.
        } else {
            statusMessage = "Connection denied for \(displayName(for: request.deviceID))"
            logActivity("xmark.seal", "Denied pairing for \(displayName(for: request.deviceID))")
        }
    }
}

extension AppState {
    static var preview: AppState {
        let a = AppState()
        a.statusMessage = "Preview"
        a.connectedDevices = [DeviceConnection(id: "Sample-iPhone", connectedAt: Date()), DeviceConnection(id: "iPad-Pro", connectedAt: Date().addingTimeInterval(-300))]
        return a
    }
}

