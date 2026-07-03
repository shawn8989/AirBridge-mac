//
//  ContentView.swift
//  AirBridge
//
//  Status dashboard: live server state, connected devices, and controls.
//

import SwiftUI
import CoreImage

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 14) {
            header

            devicesCard

            controlsCard

            footer
        }
        .padding(18)
        .frame(minWidth: 380, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $appState.pendingPairRequest) { request in
            PairingPromptView(request: request) { allowed in
                Task { await appState.handlePairingDecision(allowed: allowed, request: request) }
            }
        }
        .sheet(isPresented: Binding(
            get: { appState.qrPayload != nil },
            set: { if !$0 { appState.hidePairingQR() } }
        )) {
            QRPairingView(payload: appState.qrPayload ?? "") {
                appState.hidePairingQR()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [Color(red: 0.31, green: 0.27, blue: 0.90),
                                                  Color(red: 0.15, green: 0.39, blue: 0.92)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 44, height: 44)
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("AirBridge")
                    .font(.title2.bold())
                Text(appState.macName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusPill
        }
    }

    private var statusPill: some View {
        let (color, text): (Color, String) = appState.inputPaused
            ? (.orange, "Input Paused")
            : (.green, "Advertising")
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
    }

    // MARK: - Devices

    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Connected Devices", systemImage: "iphone.radiowaves.left.and.right")
                .font(.subheadline.weight(.semibold))

            if appState.connectedDevices.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "iphone.slash")
                        .foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No devices connected")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("Open AirPad on your iPhone — same Wi-Fi network.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else {
                ForEach(appState.connectedDevices) { device in
                    HStack(spacing: 10) {
                        Image(systemName: "iphone")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(device.id.prefix(13)) + "…")
                                .font(.callout.monospaced())
                            Text("Connected \(device.connectedAt.formatted(date: .omitted, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Forget") {
                            appState.forgetDevice(device.id)
                        }
                        .controlSize(.small)
                        .help("Remove this device's pairing; it will need approval to reconnect.")
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Controls

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Controls", systemImage: "switch.2")
                .font(.subheadline.weight(.semibold))

            Toggle(isOn: $appState.inputPaused) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Pause Input")
                    Text("Temporarily ignore mouse, keyboard, and gestures from phones.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Toggle(isOn: Binding(
                get: { appState.launchAtLogin },
                set: { appState.setLaunchAtLogin($0) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Launch at Login")
                    Text("Start AirBridge automatically so your Mac is always reachable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Button {
                appState.showPairingQR()
            } label: {
                Label("Show Pairing QR…", systemImage: "qrcode")
            }
            .help("Pair a new iPhone instantly by scanning — no approval dialog needed.")

            Divider()

            HStack(spacing: 8) {
                Image(systemName: appState.accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(appState.accessibilityGranted ? .green : .orange)
                Text(appState.accessibilityGranted
                     ? "Accessibility permission granted"
                     : "Accessibility permission needed to control this Mac")
                    .font(.caption)
                Spacer()
                if !appState.accessibilityGranted {
                    Button("Open Settings") { appState.openAccessibilitySettings() }
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text(appState.statusMessage)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text("v\(appState.appVersion)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// A sheet prompting the user to allow/deny first-time device pairing.
struct PairingPromptView: View {
    let request: PairRequest
    let onDecision: (Bool) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
            Text("Allow this iPhone to control your Mac?")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Device ID: \(request.deviceID)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text("Only allow devices you recognize. You can revoke access anytime with Forget.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Deny") { onDecision(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Allow") { onDecision(true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 340)
    }
}

/// Displays a one-time pairing QR code for AirPad to scan.
struct QRPairingView: View {
    let payload: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("Pair a new iPhone")
                .font(.headline)
            if let image = Self.qrImage(from: payload) {
                Image(nsImage: image)
                    .interpolation(.none)   // crisp QR modules
                    .resizable()
                    .frame(width: 220, height: 220)
                    .padding(10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
            } else {
                Text("Could not generate QR code.")
                    .foregroundStyle(.secondary)
            }
            Text("In AirPad, tap “Scan QR” and point the camera here.\nThe code works once and expires in 2 minutes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Done") { onClose() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(minWidth: 300)
    }

    private static func qrImage(from string: String) -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState.preview)
}
