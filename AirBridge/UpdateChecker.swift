//
//  UpdateChecker.swift
//  AirBridge
//
//  Because AirBridge ships outside the Mac App Store, it checks GitHub
//  Releases for a newer version (on launch + daily) and surfaces a banner.
//  Fails silently offline; never blocks anything.
//

import Foundation
import Combine

@MainActor
final class UpdateChecker: ObservableObject {
    struct Update: Equatable {
        let version: String
        let url: URL
    }

    @Published var available: Update?
    /// Set after a manual check that found nothing, so the UI can say
    /// "you're up to date" rather than appearing to do nothing.
    @Published var lastCheckFoundNothing = false
    @Published var checking = false

    private static let releasesAPI = URL(string: "https://api.github.com/repos/shawn8989/AirBridge-mac/releases/latest")!
    private static let releasesPage = URL(string: "https://github.com/shawn8989/AirBridge-mac/releases/latest")!
    private var timer: Timer?

    /// User-initiated check. Reports the "already current" case, which the
    /// automatic check deliberately stays silent about.
    func checkNow() {
        guard !checking else { return }
        checking = true
        lastCheckFoundNothing = false
        Task {
            await fetch()
            checking = false
            lastCheckFoundNothing = (available == nil)
        }
    }

    func check() {
        Task { await fetch() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            Task { @MainActor [weak self] in await self?.fetch() }
        }
    }

    private func fetch() async {
        guard let (data, response) = try? await URLSession.shared.data(from: Self.releasesAPI),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else { return }

        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        if Self.isVersion(latest, newerThan: current) {
            let url = (obj["html_url"] as? String).flatMap(URL.init(string:)) ?? Self.releasesPage
            available = Update(version: latest, url: url)
        }
    }

    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let av = a.split(separator: ".").map { Int($0) ?? 0 }
        let bv = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(av.count, bv.count) {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
