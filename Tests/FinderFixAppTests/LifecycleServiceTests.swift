import Carbon
import XCTest
@testable import FinderFixApp

@MainActor
final class LoginItemServiceTests: XCTestCase {
    func testEnableRegistersAnUnregisteredItem() throws {
        let system: FakeLoginItemSystem = FakeLoginItemSystem(status: .notRegistered)
        system.statusAfterRegister = .enabled
        let service: LoginItemService = LoginItemService(system: system)

        let result: LoginItemUpdateResult = try service.setEnabled(true)

        XCTAssertEqual(result, .enabled)
        XCTAssertEqual(system.registerCallCount, 1)
        XCTAssertEqual(system.unregisterCallCount, 0)
        XCTAssertEqual(service.status, .enabled)
    }

    func testPendingApprovalIsNotRegisteredAgainAndCanBeDisabled() throws {
        let system: FakeLoginItemSystem = FakeLoginItemSystem(status: .requiresApproval)
        let service: LoginItemService = LoginItemService(system: system)

        XCTAssertEqual(try service.setEnabled(true), .requiresApproval)
        XCTAssertEqual(system.registerCallCount, 0)
        XCTAssertTrue(service.isEnabled)

        XCTAssertEqual(try service.setEnabled(false), .disabled)
        XCTAssertEqual(system.unregisterCallCount, 1)
        XCTAssertEqual(service.status, .notRegistered)
    }

    func testRegistrationFailureIsTypedAndPreservesState() {
        let system: FakeLoginItemSystem = FakeLoginItemSystem(status: .notRegistered)
        system.registerError = StubServiceError.operationFailed
        let service: LoginItemService = LoginItemService(system: system)

        XCTAssertThrowsError(try service.setEnabled(true)) { error in
            guard let loginItemError: LoginItemError = error as? LoginItemError,
                  case .registrationFailed = loginItemError else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
        XCTAssertEqual(system.status, .notRegistered)
        XCTAssertEqual(system.registerCallCount, 1)
    }

    func testSystemSettingsActionIsForwarded() {
        let system: FakeLoginItemSystem = FakeLoginItemSystem(status: .requiresApproval)
        let service: LoginItemService = LoginItemService(system: system)

        service.openSystemSettingsLoginItems()

        XCTAssertEqual(system.openSettingsCallCount, 1)
    }
}

@MainActor
final class GlobalHotKeyManagerTests: XCTestCase {
    func testSuccessfulRegistrationAndTeardownCheckEverySystemCall() {
        let system: FakeGlobalHotKeySystem = FakeGlobalHotKeySystem()
        let manager: GlobalHotKeyManager = GlobalHotKeyManager(system: system)

        assertSuccess(manager.register(action: {}))
        XCTAssertTrue(manager.isRegistered)
        XCTAssertEqual(system.installCallCount, 1)
        XCTAssertEqual(system.registerCallCount, 1)

        assertSuccess(manager.unregister())
        XCTAssertFalse(manager.isRegistered)
        XCTAssertEqual(system.unregisterCallCount, 1)
        XCTAssertEqual(system.removeCallCount, 1)
    }

    func testHandlerInstallationFailureDoesNotAttemptHotKeyRegistration() {
        let system: FakeGlobalHotKeySystem = FakeGlobalHotKeySystem()
        system.installStatus = -50
        system.installReference = nil
        let manager: GlobalHotKeyManager = GlobalHotKeyManager(system: system)

        assertFailure(
            manager.register(action: {}),
            expected: .systemCallFailed(operation: .installEventHandler, code: -50)
        )
        XCTAssertFalse(manager.isRegistered)
        XCTAssertEqual(system.registerCallCount, 0)
        XCTAssertEqual(system.removeCallCount, 0)
    }

    func testRegistrationFailureUnwindsTheInstalledHandler() {
        let system: FakeGlobalHotKeySystem = FakeGlobalHotKeySystem()
        system.registerStatus = -9876
        system.registerReference = nil
        let manager: GlobalHotKeyManager = GlobalHotKeyManager(system: system)

        assertFailure(
            manager.register(action: {}),
            expected: .systemCallFailed(operation: .registerHotKey, code: -9876)
        )
        XCTAssertFalse(manager.isRegistered)
        XCTAssertEqual(system.removeCallCount, 1)
        XCTAssertEqual(system.unregisterCallCount, 0)
    }

    func testCleanupFailureIsReportedAndCanBeRetried() {
        let system: FakeGlobalHotKeySystem = FakeGlobalHotKeySystem()
        system.registerStatus = -9876
        system.registerReference = nil
        system.removeStatus = -50
        let manager: GlobalHotKeyManager = GlobalHotKeyManager(system: system)

        assertFailure(
            manager.register(action: {}),
            expected: .systemCallFailed(
                operation: .registerHotKey,
                code: -9876,
                cleanupOperation: .removeEventHandler,
                cleanupCode: -50
            )
        )
        XCTAssertEqual(system.removeCallCount, 1)

        system.removeStatus = noErr
        assertSuccess(manager.unregister())
        XCTAssertEqual(system.removeCallCount, 2)
    }

    func testFailedHotKeyUnregistrationKeepsHandlerInstalled() {
        let system: FakeGlobalHotKeySystem = FakeGlobalHotKeySystem()
        let manager: GlobalHotKeyManager = GlobalHotKeyManager(system: system)
        assertSuccess(manager.register(action: {}))
        system.unregisterStatus = -50

        assertFailure(
            manager.unregister(),
            expected: .systemCallFailed(operation: .unregisterHotKey, code: -50)
        )
        XCTAssertTrue(manager.isRegistered)
        XCTAssertEqual(system.removeCallCount, 0)
    }

    private func assertSuccess(
        _ result: Result<Void, GlobalHotKeyError>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case let .failure(error) = result {
            XCTFail("Expected success, received \(error)", file: file, line: line)
        }
    }

    private func assertFailure(
        _ result: Result<Void, GlobalHotKeyError>,
        expected: GlobalHotKeyError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success:
            XCTFail("Expected failure", file: file, line: line)
        case let .failure(error):
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }
}

private enum StubServiceError: LocalizedError {
    case operationFailed

    var errorDescription: String? {
        "Stub operation failed."
    }
}

@MainActor
private final class FakeLoginItemSystem: LoginItemSystemServicing {
    var status: LoginItemRegistrationStatus
    var statusAfterRegister: LoginItemRegistrationStatus = .enabled
    var statusAfterUnregister: LoginItemRegistrationStatus = .notRegistered
    var registerError: (any Error)?
    var unregisterError: (any Error)?
    private(set) var registerCallCount: Int = 0
    private(set) var unregisterCallCount: Int = 0
    private(set) var openSettingsCallCount: Int = 0

    init(status: LoginItemRegistrationStatus) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        if let registerError {
            throw registerError
        }
        status = statusAfterRegister
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let unregisterError {
            throw unregisterError
        }
        status = statusAfterUnregister
    }

    func openSystemSettingsLoginItems() {
        openSettingsCallCount += 1
    }
}

@MainActor
private final class FakeGlobalHotKeySystem: GlobalHotKeySystemServicing {
    var installStatus: OSStatus = noErr
    var installReference: EventHandlerRef? = OpaquePointer(bitPattern: 1)
    var registerStatus: OSStatus = noErr
    var registerReference: EventHotKeyRef? = OpaquePointer(bitPattern: 2)
    var unregisterStatus: OSStatus = noErr
    var removeStatus: OSStatus = noErr
    private(set) var installCallCount: Int = 0
    private(set) var registerCallCount: Int = 0
    private(set) var unregisterCallCount: Int = 0
    private(set) var removeCallCount: Int = 0

    func installEventHandler(
        handler: EventHandlerUPP,
        userData: UnsafeMutableRawPointer
    ) -> CarbonReferenceResult<EventHandlerRef> {
        installCallCount += 1
        return CarbonReferenceResult(status: installStatus, reference: installReference)
    }

    func registerHotKey(
        keyCode: UInt32,
        modifiers: UInt32,
        identifier: EventHotKeyID
    ) -> CarbonReferenceResult<EventHotKeyRef> {
        registerCallCount += 1
        return CarbonReferenceResult(status: registerStatus, reference: registerReference)
    }

    func unregisterHotKey(_ reference: EventHotKeyRef) -> OSStatus {
        unregisterCallCount += 1
        return unregisterStatus
    }

    func removeEventHandler(_ reference: EventHandlerRef) -> OSStatus {
        removeCallCount += 1
        return removeStatus
    }
}
