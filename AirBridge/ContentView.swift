//
//  ContentView.swift
//  AirBridge
//
//  The 2.0 dashboard: Status / Devices / Activity tabs, live metrics,
//  first-run checklist, and quick controls.
//

import SwiftUI
import CoreImage

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    private enum Tab: String, CaseIterable, Identifiable {
        case status = "Status"
        case devices = "Devices"
        case activity = "Activity"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .status: return "gauge.with.dots.needle.50percent"
            case .devices: return "iphone"
            case .activity: return "list.bullet.rectangle"
            }
        }
    }

    @State private var tab: Tab = .status

    var body: some View {
        VStack(spacing: 12) {
            header

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Label(t.rawValue, systemImage: t.icon).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch tab {
                case .status: StatusTab()
                case .devices: DevicesTab()
                case .activity: ActivityTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            footer
        }
        .padding(16)
        .frame(width: 430, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.snappy(duration: 0.2), value: appState.connectedDevices)
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

    private var header: some View {
        HStack(spacing: 12) {
            BrandIcon(size: 42)
            VStack(alignment: .leading, spacing: 1) {
                Text("Wield Host")
                    .font(.title2.bold())
                Text(appState.macName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill()
        }
    }

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

// MARK: - Shared bits

struct BrandIcon: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27)
                .fill(LinearGradient(colors: [Color(red: 0.31, green: 0.27, blue: 0.90),
                                              Color(red: 0.15, green: 0.39, blue: 0.92)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: size, height: size)
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

struct StatusPill: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        let (color, text): (Color, String) = {
            if !appState.serverEnabled { return (.gray, "Off") }
            if appState.inputPaused { return (.orange, "Paused") }
            if !appState.connectedDevices.isEmpty { return (.green, "Connected") }
            return (.blue, "Advertising")
        }()
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Status tab

private struct StatusTab: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("airbridge.setupDismissed") private var setupDismissed = false

    private var needsSetup: Bool {
        !appState.accessibilityOK || !appState.screenRecordingOK ||
        (!setupDismissed && appState.knownDeviceIDs.isEmpty && appState.connectedDevices.isEmpty)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let update = appState.updateChecker.available {
                    updateBanner(update)
                } else if appState.updateChecker.lastCheckFoundNothing {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Wield Host is up to date")
                            .font(.callout)
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                }

                if needsSetup {
                    SetupChecklist(dismiss: { setupDismissed = true })
                }

                liveCard

                controlsCard
            }
        }
        .scrollIndicators(.hidden)
    }

    private func updateBanner(_ update: UpdateChecker.Update) -> some View {
        Button {
            NSWorkspace.shared.open(update.url)
        } label: {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                Text("Wield Host \(update.version) is available")
                    .font(.callout.weight(.medium))
                Spacer()
                Text("Get Update")
                    .font(.callout.weight(.semibold))
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var liveCard: some View {
        Card {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.title3)
                            .foregroundStyle(appState.serverEnabled ? Color.accentColor : .secondary)
                            .symbolEffect(.variableColor.iterative.reversing,
                                          options: .repeating,
                                          isActive: appState.serverEnabled && !appState.inputPaused)
                        Text(appState.serverEnabled
                             ? (appState.connectedDevices.isEmpty ? "Waiting for Wield…" : "Live")
                             : "Server is off")
                            .font(.headline)
                    }
                    Text(appState.connectedDevices.isEmpty
                         ? "Open Wield on your iPhone — same Wi-Fi network."
                         : "\(appState.connectedDevices.count) device\(appState.connectedDevices.count == 1 ? "" : "s") connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(appState.eventsPerSecond)")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy, value: appState.eventsPerSecond)
                    Text("events/sec")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Sparkline(values: appState.recentRates)
                .frame(height: 36)
        }
    }

    private var controlsCard: some View {
        Card {
            Label("Controls", systemImage: "switch.2")
                .font(.subheadline.weight(.semibold))

            Toggle("Advertise on the network", isOn: $appState.serverEnabled)
                .toggleStyle(.switch)
            Toggle("Pause input from phones", isOn: $appState.inputPaused)
                .toggleStyle(.switch)
                .disabled(!appState.serverEnabled)
            Toggle("Launch at Login", isOn: Binding(
                get: { appState.launchAtLogin },
                set: { appState.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch)
            Toggle("Notify on connect / disconnect", isOn: $appState.notifyOnConnect)
                .toggleStyle(.switch)

            Divider()

            Button {
                appState.showPairingQR()
            } label: {
                Label("Show Pairing QR…", systemImage: "qrcode")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
    }
}

/// First-run checklist; live-updates as permission is granted / devices pair.
private struct SetupChecklist: View {
    @EnvironmentObject private var appState: AppState
    var dismiss: () -> Void

    var body: some View {
        Card {
            HStack {
                Label("Get set up", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if appState.accessibilityOK {
                    Button("Hide") { dismiss() }
                        .controlSize(.small)
                }
            }

            if runningTranslocated {
                translocationWarning
            }

            checklistRow(done: appState.accessibilityOK,
                         title: "Allow Wield Host to control this Mac",
                         subtitle: "System Settings → Privacy & Security → Accessibility") {
                if !appState.accessibilityOK {
                    Button("Open Settings") { appState.openAccessibilitySettings() }
                        .controlSize(.small)
                }
            }

            checklistRow(done: appState.screenRecordingOK,
                         title: "Allow Screen Recording (for Live Screen)",
                         subtitle: "System Settings → Privacy & Security → Screen Recording") {
                if !appState.screenRecordingOK {
                    Button("Open Settings") { appState.openScreenRecordingSettings() }
                        .controlSize(.small)
                }
            }

            checklistRow(done: !appState.knownDeviceIDs.isEmpty || !appState.connectedDevices.isEmpty,
                         title: "Get Wield on your iPhone",
                         subtitle: "App Store → Wield, then open it on the same Wi-Fi") { EmptyView() }

            checklistRow(done: !appState.knownDeviceIDs.isEmpty || !appState.connectedDevices.isEmpty,
                         title: "Pair your iPhone",
                         subtitle: "Fastest: scan a pairing code") {
                Button("Show QR") { appState.showPairingQR() }
                    .controlSize(.small)
            }
        }
    }

    /// macOS runs a downloaded app from a randomized read-only copy until it is
    /// moved to Applications ("app translocation"). Accessibility granted to
    /// that copy is silently discarded — and because moving the cursor needs no
    /// permission at all, the app looks perfectly connected while every click
    /// and keystroke is dropped. It is the single most confusing way this app
    /// can fail, so say so before the user spends an hour on it.
    private var runningTranslocated: Bool {
        Bundle.main.bundlePath.contains("/AppTranslocation/")
    }

    private var translocationWarning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Move Wield Host to your Applications folder")
                    .font(.subheadline.weight(.semibold))
                Text("It is running from a temporary copy, so macOS will discard the "
                     + "permissions below no matter how many times you grant them. "
                     + "Quit, drag the app to Applications, and open it from there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func checklistRow<Trailing: View>(done: Bool, title: String, subtitle: String,
                                              @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(done ? .green : .secondary)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
    }
}

/// Tiny dependency-free sparkline of the recent event rates.
private struct Sparkline: View {
    let values: [Int]

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let maxValue = max(values.max() ?? 1, 10)
            let stepX = size.width / CGFloat(max(values.count - 1, 1))
            var path = Path()
            for (i, v) in values.enumerated() {
                let x = CGFloat(i) * stepX
                let y = size.height - (CGFloat(v) / CGFloat(maxValue)) * (size.height - 2) - 1
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            // Soft fill under the line.
            var fill = path
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(
                Gradient(colors: [Color.accentColor.opacity(0.25), .clear]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        }
    }
}

// MARK: - Devices tab

private struct DevicesTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var renamingID: String?
    @State private var renameText = ""

    private var offlineKnownIDs: [String] {
        appState.knownDeviceIDs.filter { id in !appState.connectedDevices.contains { $0.id == id } }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Card {
                    Label("Connected", systemImage: "iphone.radiowaves.left.and.right")
                        .font(.subheadline.weight(.semibold))
                    if appState.connectedDevices.isEmpty {
                        Text("No devices connected. Open Wield on your iPhone — same Wi-Fi network.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(appState.connectedDevices) { device in
                            deviceRow(id: device.id, connectedAt: device.connectedAt, online: true)
                        }
                    }
                }

                if !offlineKnownIDs.isEmpty {
                    Card {
                        Label("Previously Paired", systemImage: "clock.arrow.circlepath")
                            .font(.subheadline.weight(.semibold))
                        ForEach(offlineKnownIDs, id: \.self) { id in
                            deviceRow(id: id, connectedAt: nil, online: false)
                        }
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .alert("Rename Device", isPresented: Binding(
            get: { renamingID != nil },
            set: { if !$0 { renamingID = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let id = renamingID { appState.setNickname(renameText, for: id) }
                renamingID = nil
            }
            Button("Cancel", role: .cancel) { renamingID = nil }
        } message: {
            Text("Leave empty to go back to the name the device reports.")
        }
    }

    private func deviceRow(id: String, connectedAt: Date?, online: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: online ? "iphone" : "iphone.slash")
                .font(.title3)
                .foregroundStyle(online ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.displayName(for: id))
                    .font(.callout.weight(.semibold))
                HStack(spacing: 6) {
                    Text(String(id.prefix(8)) + "…")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                    if let connectedAt {
                        Text("· since \(connectedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if online, let total = appState.deviceEventTotals[id] {
                        Text("· \(total) events")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            Spacer()
            Button {
                renameText = appState.nicknames[id] ?? appState.deviceNames[id] ?? ""
                renamingID = id
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Rename")
            Button("Forget") {
                appState.forgetDevice(id)
                appState.deviceNames.removeValue(forKey: id)
                appState.nicknames.removeValue(forKey: id)
            }
            .controlSize(.small)
            .help("Remove this device's pairing; it will need approval to reconnect.")
        }
        .padding(8)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Activity tab

private struct ActivityTab: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Card {
            HStack {
                Label("Recent Activity", systemImage: "list.bullet.rectangle")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !appState.activity.isEmpty {
                    Button("Clear") { appState.activity.removeAll() }
                        .controlSize(.small)
                }
            }
            if appState.activity.isEmpty {
                Text("Nothing yet. Connections, pairings, and clipboard transfers will show up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(appState.activity) { entry in
                            HStack(spacing: 10) {
                                Image(systemName: entry.symbol)
                                    .frame(width: 22)
                                    .foregroundStyle(Color.accentColor)
                                Text(entry.text)
                                    .font(.callout)
                                Spacer()
                                Text(entry.date, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 6)
                            Divider().opacity(0.4)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Pairing sheets (unchanged behavior)

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
            Text("In Wield, tap “Scan QR” and point the camera here.\nThe code works once and expires in 2 minutes.")
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
