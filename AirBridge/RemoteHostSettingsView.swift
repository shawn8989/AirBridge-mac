import SwiftUI
import AppKit

struct RemoteHostSettingsView: View {
    @ObservedObject private var availability = RemoteAvailability.shared
    @ObservedObject private var files = SharedFolderStore.shared
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Away from home", systemImage: "network").font(.headline)
            Toggle("Keep available while plugged in", isOn: $availability.keepAvailable)
            Text("Allows display sleep. Keep Wield Host and Tailscale running. Shutdown, manual sleep, closing a laptop, or a restart awaiting login may prevent access.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Set up Tailscale", destination: URL(string: "https://tailscale.com/download")!)
            Divider()
            Label("Shared folders", systemImage: "folder").font(.headline)
            Text("Securely paired phones can browse these folders and transfer individual files. Removing a folder stops further access.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(files.folders) { folder in
                HStack {
                    Text(folder.name)
                    Spacer()
                    Button("Remove") { files.remove(folder.id) }
                }
            }
            Button("Choose a folder…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true; panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url {
                    do { try files.add(url); error = nil } catch { self.error = error.localizedDescription }
                }
            }
            if let message = error ?? availability.error { Text(message).font(.caption).foregroundStyle(.red) }
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}
