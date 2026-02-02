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
    }
}
