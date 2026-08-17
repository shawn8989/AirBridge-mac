//
//  AirBridgeApp.swift
//  AirBridge
//
//  Created by shunathon Owens on 11/24/25.
//

import SwiftUI

@main
struct AirBridgeApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        Window("AirBridge", id: "main") {
            ContentView()
                .environmentObject(appState)
        }
        .windowResizability(.contentSize)
        .commands {
            // The phone tells users to update from here, so the menu item has
            // to exist and has to report the "already current" case too.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    appState.updateChecker.checkNow()
                }
                .disabled(appState.updateChecker.checking)
            }
        }

        Settings {
            ContentView()
                .environmentObject(appState)
        }

        // Menu bar presence: a mini dashboard, controllable with the window closed.
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(appState)
        } label: {
            MenuBarLabel()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Status-reflecting menu bar icon: slashed when the server is off, filled
/// phone when a device is connected, plain antenna otherwise.
struct MenuBarLabel: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Image(systemName: symbol)
    }

    private var symbol: String {
        if !appState.serverEnabled { return "antenna.radiowaves.left.and.right.slash" }
        if !appState.connectedDevices.isEmpty { return "iphone.radiowaves.left.and.right" }
        return "antenna.radiowaves.left.and.right"
    }
}

/// Mini dashboard shown from the status bar icon (window-style popover).
struct MenuBarContent: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                BrandIcon(size: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("AirBridge").font(.headline)
                    Text(appState.connectedDevices.isEmpty
                         ? "No devices connected"
                         : "\(appState.connectedDevices.count) device\(appState.connectedDevices.count == 1 ? "" : "s") · \(appState.eventsPerSecond)/s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                StatusPill()
            }

            if !appState.connectedDevices.isEmpty {
                Divider()
                ForEach(appState.connectedDevices) { device in
                    HStack(spacing: 8) {
                        Image(systemName: "iphone")
                            .foregroundStyle(Color.accentColor)
                        Text(appState.displayName(for: device.id))
                            .font(.callout)
                        Spacer()
                        if let total = appState.deviceEventTotals[device.id] {
                            Text("\(total)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Divider()

            Toggle("Advertise on network", isOn: $appState.serverEnabled)
                .toggleStyle(.switch)
            Toggle("Pause input", isOn: $appState.inputPaused)
                .toggleStyle(.switch)
                .disabled(!appState.serverEnabled)

            Divider()

            HStack {
                Button {
                    openMainWindow()
                    appState.showPairingQR()
                } label: {
                    Label("Pair", systemImage: "qrcode")
                }
                Button {
                    openMainWindow()
                } label: {
                    Label("Open", systemImage: "macwindow")
                }
                Spacer()
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                }
                .keyboardShortcut("q")
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 280)
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    }
}
