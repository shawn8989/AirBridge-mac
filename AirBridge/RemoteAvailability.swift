import Foundation
import Combine
import IOKit.pwr_mgt
import IOKit.ps
import ServiceManagement

@MainActor
final class RemoteAvailability: ObservableObject {
    static let shared = RemoteAvailability()
    @Published var keepAvailable: Bool {
        didSet {
            UserDefaults.standard.set(keepAvailable, forKey: "remote.keepAvailable")
            updateAssertion()
        }
    }
    @Published private(set) var error: String?
    private var assertion: IOPMAssertionID = 0
    private var powerTimer: Timer?
    static var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    private init() {
        keepAvailable = UserDefaults.standard.bool(forKey: "remote.keepAvailable")
        updateAssertion()
        powerTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateAssertion() }
        }
    }
    private func updateAssertion() {
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
        error = nil
        guard keepAvailable else { return }
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue(),
           source as String == kIOPSBatteryPowerValue { return }
        let status = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), "Wield remote availability" as CFString, &assertion)
        if status == kIOReturnSuccess {
            // This assertion permits display sleep and does not override lid
            // closure, manual sleep, or sleep while running on battery power.
            // PreventUserIdleSystemSleep does not keep the display awake.
        } else {
            assertion = 0
            error = "macOS could not keep this Mac available (\(status))."
        }
    }
}
