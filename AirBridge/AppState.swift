//
//  AppState.swift
//  AirBridge
//
//  Manages shared state, pairing prompts, and status messages.
//

import Foundation
import SwiftUI
import Combine

/// Represents a first-time pairing request from an unknown device.
struct PairRequest: Identifiable {
    let id = UUID()
    let deviceID: String
    let proposedSecret: Data
    let continuation: CheckedContinuation<Bool, Never>
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
        networkManager = NetworkManager(
            onReceivePacket: { [weak self] packet in
                await self?.handle(packet: packet)
            },
            onUnknownDevice: { [weak self] deviceID, proposedSecret in
                return await self?.promptPairing(deviceID: deviceID, proposedSecret: proposedSecret) ?? false
            },
            onDeviceConnected: { [weak self] deviceID in
                Task { @MainActor in
                    guard let self else { return }
                    if !self.connectedDevices.contains(where: { $0.id == deviceID }) {
                        self.connectedDevices.append(DeviceConnection(id: deviceID, connectedAt: Date()))
                    }
                    self.statusMessage = "Connected: \(deviceID)"
                }
            },
            onDeviceDisconnected: { [weak self] deviceID in
                Task { @MainActor in
                    guard let self else { return }
                    if let id = deviceID {
                        self.connectedDevices.removeAll { $0.id == id }
                        self.statusMessage = "Disconnected: \(id)"
                    } else {
                        self.statusMessage = "Disconnected"
                    }
                }
            }
        )
        Task { await networkManager.start() }
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

    func promptPairing(deviceID: String, proposedSecret: Data) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let request = PairRequest(deviceID: deviceID, proposedSecret: proposedSecret, continuation: continuation)
            pendingPairRequest = request
        }
    }

    func handlePairingDecision(allowed: Bool, request: PairRequest) async {
        pendingPairRequest = nil
        request.continuation.resume(returning: allowed)
        if allowed {
            do {
                try securityManager.storeSharedSecret(request.proposedSecret, for: request.deviceID)
                statusMessage = "Paired with \(request.deviceID)"
            } catch {
                statusMessage = "Keychain error: \(error.localizedDescription)"
            }
        } else {
            statusMessage = "Connection denied for \(request.deviceID)"
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

