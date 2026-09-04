import Carbon
import Foundation

private let globalHotKeySignature: OSType = 0x46465821 // FFX!
private let globalHotKeyIdentifier: UInt32 = 1

enum GlobalHotKeyOperation: String, Equatable, Sendable {
    case installEventHandler
    case registerHotKey
    case unregisterHotKey
    case removeEventHandler
}

enum GlobalHotKeyError: LocalizedError, Equatable, Sendable {
    case systemCallFailed(
        operation: GlobalHotKeyOperation,
        code: Int32,
        cleanupOperation: GlobalHotKeyOperation? = nil,
        cleanupCode: Int32? = nil
    )
    case missingReference(operation: GlobalHotKeyOperation)

    var errorDescription: String? {
        switch self {
        case let .systemCallFailed(operation, code, cleanupOperation, cleanupCode):
            var message: String = "The global shortcut could not \(operation.description) (error \(code))."
            if let cleanupOperation, let cleanupCode {
                message += " Cleanup could not \(cleanupOperation.description) (error \(cleanupCode))."
            }
            return message
        case let .missingReference(operation):
            return "The global shortcut could not \(operation.description) because macOS returned no registration reference."
        }
    }
}

struct CarbonReferenceResult<Reference> {
    let status: OSStatus
    let reference: Reference?
}

@MainActor
protocol GlobalHotKeySystemServicing: AnyObject {
    func installEventHandler(
        handler: EventHandlerUPP,
        userData: UnsafeMutableRawPointer
    ) -> CarbonReferenceResult<EventHandlerRef>
    func registerHotKey(
        keyCode: UInt32,
        modifiers: UInt32,
        identifier: EventHotKeyID
    ) -> CarbonReferenceResult<EventHotKeyRef>
    func unregisterHotKey(_ reference: EventHotKeyRef) -> OSStatus
    func removeEventHandler(_ reference: EventHandlerRef) -> OSStatus
}

@MainActor
private final class CarbonGlobalHotKeySystem: GlobalHotKeySystemServicing {
    func installEventHandler(
        handler: EventHandlerUPP,
        userData: UnsafeMutableRawPointer
    ) -> CarbonReferenceResult<EventHandlerRef> {
        var eventType: EventTypeSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var reference: EventHandlerRef?
        let status: OSStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            userData,
            &reference
        )
        return CarbonReferenceResult(status: status, reference: reference)
    }

    func registerHotKey(
        keyCode: UInt32,
        modifiers: UInt32,
        identifier: EventHotKeyID
    ) -> CarbonReferenceResult<EventHotKeyRef> {
        var reference: EventHotKeyRef?
        let status: OSStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        return CarbonReferenceResult(status: status, reference: reference)
    }

    func unregisterHotKey(_ reference: EventHotKeyRef) -> OSStatus {
        UnregisterEventHotKey(reference)
    }

    func removeEventHandler(_ reference: EventHandlerRef) -> OSStatus {
        RemoveEventHandler(reference)
    }
}

@MainActor
private final class GlobalHotKeyCallbackContext {
    weak var manager: GlobalHotKeyManager?

    init(manager: GlobalHotKeyManager) {
        self.manager = manager
    }
}

@MainActor
final class GlobalHotKeyManager {
    private let system: any GlobalHotKeySystemServicing
    private var hotKeyReference: EventHotKeyRef?
    private var eventHandlerReference: EventHandlerRef?
    private var callbackContextPointer: UnsafeMutableRawPointer?
    private var action: (() -> Void)?

    init() {
        self.system = CarbonGlobalHotKeySystem()
    }

    init(system: any GlobalHotKeySystemServicing) {
        self.system = system
    }

    var isRegistered: Bool {
        hotKeyReference != nil && eventHandlerReference != nil
    }

    @discardableResult
    func register(action: @escaping () -> Void) -> Result<Void, GlobalHotKeyError> {
        switch unregister() {
        case .success:
            break
        case let .failure(error):
            return .failure(error)
        }

        let context: GlobalHotKeyCallbackContext = GlobalHotKeyCallbackContext(manager: self)
        let contextPointer: UnsafeMutableRawPointer = Unmanaged.passRetained(context).toOpaque()
        let installation: CarbonReferenceResult<EventHandlerRef> = system.installEventHandler(
            handler: globalHotKeyEventHandler,
            userData: contextPointer
        )

        guard installation.status == noErr else {
            let cleanupCode: OSStatus? = installation.reference.map(system.removeEventHandler)
            if let reference: EventHandlerRef = installation.reference,
               cleanupCode != noErr {
                eventHandlerReference = reference
                callbackContextPointer = contextPointer
            } else {
                Unmanaged<GlobalHotKeyCallbackContext>.fromOpaque(contextPointer).release()
            }
            return .failure(
                .systemCallFailed(
                    operation: .installEventHandler,
                    code: Int32(installation.status),
                    cleanupOperation: cleanupCode == nil || cleanupCode == noErr ? nil : .removeEventHandler,
                    cleanupCode: cleanupCode == noErr ? nil : cleanupCode.map { Int32($0) }
                )
            )
        }
        guard let handlerReference: EventHandlerRef = installation.reference else {
            Unmanaged<GlobalHotKeyCallbackContext>.fromOpaque(contextPointer).release()
            return .failure(.missingReference(operation: .installEventHandler))
        }

        eventHandlerReference = handlerReference
        callbackContextPointer = contextPointer
        self.action = action

        let hotKeyID: EventHotKeyID = EventHotKeyID(
            signature: globalHotKeySignature,
            id: globalHotKeyIdentifier
        )
        let registration: CarbonReferenceResult<EventHotKeyRef> = system.registerHotKey(
            keyCode: UInt32(kVK_ANSI_F),
            modifiers: UInt32(cmdKey | optionKey),
            identifier: hotKeyID
        )

        guard registration.status == noErr else {
            if let unexpectedReference: EventHotKeyRef = registration.reference {
                hotKeyReference = unexpectedReference
                let unregisterStatus: OSStatus = system.unregisterHotKey(unexpectedReference)
                if unregisterStatus != noErr {
                    return .failure(
                        .systemCallFailed(
                            operation: .registerHotKey,
                            code: Int32(registration.status),
                            cleanupOperation: .unregisterHotKey,
                            cleanupCode: Int32(unregisterStatus)
                        )
                    )
                }
                hotKeyReference = nil
            }

            let removeStatus: OSStatus = system.removeEventHandler(handlerReference)
            self.action = nil
            if removeStatus == noErr {
                releaseCallbackContext()
                eventHandlerReference = nil
            }
            return .failure(
                .systemCallFailed(
                    operation: .registerHotKey,
                    code: Int32(registration.status),
                    cleanupOperation: removeStatus == noErr ? nil : .removeEventHandler,
                    cleanupCode: removeStatus == noErr ? nil : Int32(removeStatus)
                )
            )
        }
        guard let registeredReference: EventHotKeyRef = registration.reference else {
            let removeStatus: OSStatus = system.removeEventHandler(handlerReference)
            self.action = nil
            if removeStatus == noErr {
                releaseCallbackContext()
                eventHandlerReference = nil
            }
            if removeStatus != noErr {
                return .failure(
                    .systemCallFailed(
                        operation: .removeEventHandler,
                        code: Int32(removeStatus)
                    )
                )
            }
            return .failure(.missingReference(operation: .registerHotKey))
        }

        hotKeyReference = registeredReference
        return .success(())
    }

    @discardableResult
    func unregister() -> Result<Void, GlobalHotKeyError> {
        if let hotKeyReference {
            let status: OSStatus = system.unregisterHotKey(hotKeyReference)
            guard status == noErr else {
                return .failure(
                    .systemCallFailed(
                        operation: .unregisterHotKey,
                        code: Int32(status)
                    )
                )
            }
            self.hotKeyReference = nil
            action = nil
        }

        if let eventHandlerReference {
            let status: OSStatus = system.removeEventHandler(eventHandlerReference)
            guard status == noErr else {
                return .failure(
                    .systemCallFailed(
                        operation: .removeEventHandler,
                        code: Int32(status)
                    )
                )
            }
            self.eventHandlerReference = nil
            releaseCallbackContext()
        }

        action = nil
        return .success(())
    }

    fileprivate func performRegisteredAction() {
        action?()
    }

    private func releaseCallbackContext() {
        guard let callbackContextPointer else { return }
        Unmanaged<GlobalHotKeyCallbackContext>.fromOpaque(callbackContextPointer).release()
        self.callbackContextPointer = nil
    }
}

private func globalHotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else {
        return OSStatus(eventNotHandledErr)
    }

    var identifier: EventHotKeyID = EventHotKeyID()
    let status: OSStatus = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr,
          identifier.signature == globalHotKeySignature,
          identifier.id == globalHotKeyIdentifier else {
        return OSStatus(eventNotHandledErr)
    }

    let context: GlobalHotKeyCallbackContext = Unmanaged<GlobalHotKeyCallbackContext>
        .fromOpaque(userData)
        .takeUnretainedValue()
    MainActor.assumeIsolated {
        context.manager?.performRegisteredAction()
    }
    return noErr
}

private extension GlobalHotKeyOperation {
    var description: String {
        switch self {
        case .installEventHandler: return "install its event handler"
        case .registerHotKey: return "register ⌥⌘F"
        case .unregisterHotKey: return "unregister ⌥⌘F"
        case .removeEventHandler: return "remove its event handler"
        }
    }
}
