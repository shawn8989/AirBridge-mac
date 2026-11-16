import Foundation
import Combine
import IOKit.pwr_mgt
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
    static var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    private init() {
        keepAvailable = UserDefaults.standard.bool(forKey: "remote.keepAvailable")
        updateAssertion()
    }
    private func updateAssertion() {
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
        error = nil
        guard keepAvailable else { return }
        let status = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), "Wield remote availability" as CFString, &assertion)
        if status == kIOReturnSuccess {
            // This assertion permits display sleep and does not override lid
            // closure, manual sleep, or sleep while running on battery power.
            IOPMAssertionSetProperty(assertion, kIOPMAssertionAppliesToLimitedPowerKey as CFString, kCFBooleanFalse)
        } else {
            assertion = 0
            error = "macOS could not keep this Mac available (\(status))."
        }
    }
}
