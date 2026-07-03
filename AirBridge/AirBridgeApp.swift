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
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        Settings {
            ContentView()
                .environmentObject(appState)
        }
        // Menu bar presence so AirBridge is controllable when the window is closed.
        MenuBarExtra("AirBridge", systemImage: "antenna.radiowaves.left.and.right") {
            MenuBarContent()
                .environmentObject(appState)
        }
    }
}

/// Compact menu shown from the status bar icon.
struct MenuBarContent: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Text(appState.connectedDevices.isEmpty
                 ? "No devices connected"
                 : "\(appState.connectedDevices.count) device\(appState.connectedDevices.count == 1 ? "" : "s") connected")

            Divider()

            Toggle("Pause Input", isOn: $appState.inputPaused)

            Toggle("Launch at Login", isOn: Binding(
                get: { appState.launchAtLogin },
                set: { appState.setLaunchAtLogin($0) }
            ))

            Divider()

            Button("Show Pairing QR…") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
                appState.showPairingQR()
            }

            Button("Open AirBridge") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            }

            Text("Version \(appState.appVersion)")

            Divider()

            Button("Quit AirBridge") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
