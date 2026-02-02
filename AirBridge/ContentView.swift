//
//  ContentView.swift
//  AirBridge
//
//  Created by shunathon Owens on 11/24/25.
//

import SwiftUI

/// A minimal view used to present pairing prompts and status.
struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                Text("AirBridge").font(.title3).bold()
                Spacer()
            }

            Text(appState.statusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if appState.connectedDevices.isEmpty {
                Text("No devices connected")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Connected Devices")
                    .font(.footnote).bold()
                ForEach(appState.connectedDevices) { device in
                    HStack {
                        Image(systemName: "iphone")
                        VStack(alignment: .leading) {
                            Text(device.id)
                            Text("Connected \(device.connectedAt.formatted(date: .omitted, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(6)
                    .background(.quaternary.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            Spacer(minLength: 0)
        }
        .frame(minWidth: 280)
        .padding()
        .sheet(item: $appState.pendingPairRequest) { request in
            PairingPromptView(request: request) { allowed in
                Task { await appState.handlePairingDecision(allowed: allowed, request: request) }
            }
        }
    }
}

/// A sheet prompting the user to allow/deny first-time device pairing.
struct PairingPromptView: View {
    let request: PairRequest
    let onDecision: (Bool) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Allow this device to connect to AirBridge?")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Device ID: \(request.deviceID)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Deny") { onDecision(false) }
                Button("Allow") { onDecision(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 320)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState.preview)
}
