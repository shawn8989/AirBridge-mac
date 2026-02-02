//
//  AirBridgeApp.swift
//  AirBridge
//
//  Created by shunathon Owens on 11/24/25.
//

// Alternate App configuration without @main to avoid duplicate entry points.

#if os(macOS)
import AppKit
#endif

import SwiftUI
import Combine

#if os(macOS)
struct AirBridgeApp_MenuOnly: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(MenuBarController.self) private var menuBarController

    var body: some Scene {
        // No visible main window; menu bar only. Provide a hidden settings scene for prompts.
        Settings {
            ContentView()
                .environmentObject(appState)
        }
    }
}
#endif
