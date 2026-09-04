import ServiceManagement

enum LoginItemRegistrationStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound

    var isRegistered: Bool {
        self == .enabled || self == .requiresApproval
    }
}

enum LoginItemUpdateResult: Equatable, Sendable {
    case unchanged(LoginItemRegistrationStatus)
    case enabled
    case requiresApproval
    case disabled
}

enum LoginItemError: LocalizedError, Equatable, Sendable {
    case serviceNotFound
    case registrationFailed(String)
    case unregistrationFailed(String)
    case unexpectedStatus(expectedEnabled: Bool, actual: LoginItemRegistrationStatus)

    var errorDescription: String? {
        switch self {
        case .serviceNotFound:
            return "FinderFix could not find its login-item registration. Move the app to Applications and try again."
        case let .registrationFailed(message):
            return "FinderFix could not enable launch at login: \(message)"
        case let .unregistrationFailed(message):
            return "FinderFix could not disable launch at login: \(message)"
        case let .unexpectedStatus(expectedEnabled, actual):
            let requestedState: String = expectedEnabled ? "enabled" : "disabled"
            return "Launch at login did not become \(requestedState) (status: \(actual.description))."
        }
    }
}

@MainActor
protocol LoginItemSystemServicing: AnyObject {
    var status: LoginItemRegistrationStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettingsLoginItems()
}

@MainActor
private final class SMAppServiceLoginItemSystem: LoginItemSystemServicing {
    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
    }

    var status: LoginItemRegistrationStatus {
        switch service.status {
        case .notRegistered:
            return .notRegistered
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .notFound
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
final class LoginItemService {
    private let system: any LoginItemSystemServicing

    init() {
        self.system = SMAppServiceLoginItemSystem()
    }

    init(system: any LoginItemSystemServicing) {
        self.system = system
    }

    var status: LoginItemRegistrationStatus {
        system.status
    }

    /// A pending approval is still a registered login item. Treating it as
    /// disabled would retry registration and would prevent explicit removal.
    var isEnabled: Bool {
        status.isRegistered
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) throws -> LoginItemUpdateResult {
        if enabled {
            return try enable()
        }
        return try disable()
    }

    func openSystemSettingsLoginItems() {
        system.openSystemSettingsLoginItems()
    }

    private func enable() throws -> LoginItemUpdateResult {
        switch status {
        case .enabled:
            return .unchanged(.enabled)
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            throw LoginItemError.serviceNotFound
        case .notRegistered:
            do {
                try system.register()
            } catch {
                throw LoginItemError.registrationFailed(error.localizedDescription)
            }
        }

        switch status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            throw LoginItemError.serviceNotFound
        case .notRegistered:
            throw LoginItemError.unexpectedStatus(
                expectedEnabled: true,
                actual: .notRegistered
            )
        }
    }

    private func disable() throws -> LoginItemUpdateResult {
        switch status {
        case .notRegistered, .notFound:
            return .unchanged(status)
        case .enabled, .requiresApproval:
            do {
                try system.unregister()
            } catch {
                throw LoginItemError.unregistrationFailed(error.localizedDescription)
            }
        }

        switch status {
        case .notRegistered:
            return .disabled
        case let currentStatus:
            throw LoginItemError.unexpectedStatus(
                expectedEnabled: false,
                actual: currentStatus
            )
        }
    }
}

private extension LoginItemRegistrationStatus {
    var description: String {
        switch self {
        case .notRegistered: return "not registered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requires approval"
        case .notFound: return "not found"
        }
    }
}
