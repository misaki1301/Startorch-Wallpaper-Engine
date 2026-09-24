import ServiceManagement

/// The parts of `SMAppService` we use, so tests can substitute a fake and never register
/// a real login item.
protocol LoginItemControlling {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemControlling {}

/// Launch-at-login state. The system owns the truth (the user can change it in
/// System Settings › General › Login Items), so this always reflects `status`
/// rather than a stored preference.
@Observable
final class LaunchAtLogin {
    private(set) var status: SMAppService.Status
    private(set) var errorMessage: String?
    @ObservationIgnored private let service: any LoginItemControlling

    init(service: any LoginItemControlling = SMAppService.mainApp) {
        self.service = service
        status = service.status
    }

    /// On, including when the user still has to approve it in System Settings.
    var isEnabled: Bool {
        status == .enabled || status == .requiresApproval
    }

    var needsApproval: Bool {
        status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func refresh() {
        status = service.status
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
