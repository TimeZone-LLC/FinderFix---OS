import ApplicationServices
import CoreGraphics
import Foundation

enum AXAttributeRead<Value> {
    case value(Value)
    case unavailable(AXError)
}

enum FinderAXWindowClassification {
    case browser(frame: CGRect)
    case dialog(size: CGSize)
    case ineligible(FinderAutomationSkipReason)
    case retryable(AXError)
}

private enum SecureContentScanResult {
    case clear
    case containsSecureField
    case indeterminate(AXError)
}

private enum DialogButtonCheckResult {
    case valid
    case invalid
    case retryable(AXError)
}

enum AXElementAccess {
    static func attributeValue(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> AXAttributeRead<CFTypeRef> {
        var value: CFTypeRef?
        let error: AXError = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard error == .success, let value else {
            return .unavailable(error)
        }
        return .value(value)
    }

    static func stringAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> AXAttributeRead<String> {
        switch attributeValue(attribute, from: element) {
        case let .value(value):
            guard let string: String = value as? String else {
                return .unavailable(.illegalArgument)
            }
            return .value(string)
        case let .unavailable(error):
            return .unavailable(error)
        }
    }

    static func boolAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> AXAttributeRead<Bool> {
        switch attributeValue(attribute, from: element) {
        case let .value(value):
            guard let boolean: Bool = value as? Bool else {
                return .unavailable(.illegalArgument)
            }
            return .value(boolean)
        case let .unavailable(error):
            return .unavailable(error)
        }
    }

    static func elementAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> AXAttributeRead<AXUIElement> {
        switch attributeValue(attribute, from: element) {
        case let .value(value):
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return .unavailable(.illegalArgument)
            }
            return .value(unsafeDowncast(value, to: AXUIElement.self))
        case let .unavailable(error):
            return .unavailable(error)
        }
    }

    static func elementsAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> AXAttributeRead<[AXUIElement]> {
        switch attributeValue(attribute, from: element) {
        case let .value(value):
            guard let elements: [AXUIElement] = value as? [AXUIElement] else {
                return .unavailable(.illegalArgument)
            }
            return .value(elements)
        case let .unavailable(error):
            return .unavailable(error)
        }
    }

    static func pointAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> AXAttributeRead<CGPoint> {
        switch attributeValue(attribute, from: element) {
        case let .value(value):
            guard CFGetTypeID(value) == AXValueGetTypeID() else {
                return .unavailable(.illegalArgument)
            }
            let axValue: AXValue = unsafeDowncast(value, to: AXValue.self)
            guard AXValueGetType(axValue) == .cgPoint else {
                return .unavailable(.illegalArgument)
            }
            var point: CGPoint = .zero
            guard AXValueGetValue(axValue, .cgPoint, &point) else {
                return .unavailable(.failure)
            }
            return .value(point)
        case let .unavailable(error):
            return .unavailable(error)
        }
    }

    static func sizeAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> AXAttributeRead<CGSize> {
        switch attributeValue(attribute, from: element) {
        case let .value(value):
            guard CFGetTypeID(value) == AXValueGetTypeID() else {
                return .unavailable(.illegalArgument)
            }
            let axValue: AXValue = unsafeDowncast(value, to: AXValue.self)
            guard AXValueGetType(axValue) == .cgSize else {
                return .unavailable(.illegalArgument)
            }
            var size: CGSize = .zero
            guard AXValueGetValue(axValue, .cgSize, &size) else {
                return .unavailable(.failure)
            }
            return .value(size)
        case let .unavailable(error):
            return .unavailable(error)
        }
    }

    static func attributeNames(of element: AXUIElement) -> AXAttributeRead<Set<String>> {
        var names: CFArray?
        let error: AXError = AXUIElementCopyAttributeNames(element, &names)
        guard error == .success, let strings: [String] = names as? [String] else {
            return .unavailable(error == .success ? .failure : error)
        }
        return .value(Set(strings))
    }

    static func actionNames(of element: AXUIElement) -> AXAttributeRead<Set<String>> {
        var names: CFArray?
        let error: AXError = AXUIElementCopyActionNames(element, &names)
        guard error == .success, let strings: [String] = names as? [String] else {
            return .unavailable(error == .success ? .failure : error)
        }
        return .value(Set(strings))
    }

    static func isAttributeSettable(
        _ attribute: CFString,
        on element: AXUIElement
    ) -> AXAttributeRead<Bool> {
        var settable: DarwinBoolean = false
        let error: AXError = AXUIElementIsAttributeSettable(element, attribute, &settable)
        guard error == .success else {
            return .unavailable(error)
        }
        return .value(settable.boolValue)
    }

    static func setPoint(
        _ point: CGPoint,
        attribute: CFString,
        on element: AXUIElement
    ) -> AXError {
        var mutablePoint: CGPoint = point
        guard let value: AXValue = AXValueCreate(.cgPoint, &mutablePoint) else {
            return .failure
        }
        return AXUIElementSetAttributeValue(element, attribute, value)
    }

    static func setSize(
        _ size: CGSize,
        attribute: CFString,
        on element: AXUIElement
    ) -> AXError {
        var mutableSize: CGSize = size
        guard let value: AXValue = AXValueCreate(.cgSize, &mutableSize) else {
            return .failure
        }
        return AXUIElementSetAttributeValue(element, attribute, value)
    }

    static func setAndVerifyPoint(
        _ point: CGPoint,
        attribute: CFString,
        on element: AXUIElement,
        tolerance: CGFloat = 1
    ) -> AXAttributeRead<CGPoint> {
        guard point.isFinite, tolerance.isFinite, tolerance >= 0 else {
            return .unavailable(.illegalArgument)
        }
        let setError: AXError = setPoint(point, attribute: attribute, on: element)
        guard setError == .success else {
            return .unavailable(setError)
        }

        switch pointAttribute(attribute, from: element) {
        case let .value(actualPoint):
            guard abs(actualPoint.x - point.x) <= tolerance,
                  abs(actualPoint.y - point.y) <= tolerance else {
                return .unavailable(.failure)
            }
            return .value(actualPoint)
        case let .unavailable(error):
            return .unavailable(error)
        }
    }

    static func setAndVerifySize(
        _ size: CGSize,
        attribute: CFString,
        on element: AXUIElement,
        tolerance: CGFloat = 1
    ) -> AXAttributeRead<CGSize> {
        guard size.isUsable, tolerance.isFinite, tolerance >= 0 else {
            return .unavailable(.illegalArgument)
        }
        let setError: AXError = setSize(size, attribute: attribute, on: element)
        guard setError == .success else {
            return .unavailable(setError)
        }

        switch sizeAttribute(attribute, from: element) {
        case let .value(actualSize):
            guard abs(actualSize.width - size.width) <= tolerance,
                  abs(actualSize.height - size.height) <= tolerance else {
                return .unavailable(.failure)
            }
            return .value(actualSize)
        case let .unavailable(error):
            return .unavailable(error)
        }
    }

    static func frame(of element: AXUIElement) -> AXAttributeRead<CGRect> {
        let position: CGPoint
        switch pointAttribute(kAXPositionAttribute as CFString, from: element) {
        case let .value(value):
            position = value
        case let .unavailable(error):
            return .unavailable(error)
        }

        let size: CGSize
        switch sizeAttribute(kAXSizeAttribute as CFString, from: element) {
        case let .value(value):
            size = value
        case let .unavailable(error):
            return .unavailable(error)
        }

        guard position.isFinite, size.isUsable else {
            return .unavailable(.illegalArgument)
        }
        return .value(CGRect(origin: position, size: size))
    }

    fileprivate static func scanForSecureTextFields(
        in root: AXUIElement,
        maximumDepth: Int = 8,
        maximumElements: Int = 128
    ) -> SecureContentScanResult {
        var pending: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var examined: Int = 0

        while !pending.isEmpty {
            guard examined < maximumElements else {
                return .indeterminate(.failure)
            }
            let current: (element: AXUIElement, depth: Int) = pending.removeFirst()
            examined += 1

            switch stringAttribute(
                kAXSubroleAttribute as CFString,
                from: current.element
            ) {
            case let .value(subrole):
                if subrole == (kAXSecureTextFieldSubrole as String) {
                    return .containsSecureField
                }
            case let .unavailable(error):
                guard error == .noValue || error == .attributeUnsupported else {
                    return .indeterminate(error)
                }
            }

            switch elementsAttribute(
                kAXChildrenAttribute as CFString,
                from: current.element
            ) {
            case let .value(children):
                guard current.depth < maximumDepth else {
                    if children.isEmpty { continue }
                    return .indeterminate(.failure)
                }
                guard examined + pending.count + children.count <= maximumElements else {
                    return .indeterminate(.failure)
                }
                pending.append(contentsOf: children.map { ($0, current.depth + 1) })
            case let .unavailable(error):
                guard error == .noValue || error == .attributeUnsupported else {
                    return .indeterminate(error)
                }
            }
        }

        return .clear
    }
}

enum FinderAXWindowClassifier {
    static func classify(_ element: AXUIElement) -> FinderAXWindowClassification {
        let role: String
        switch AXElementAccess.stringAttribute(kAXRoleAttribute as CFString, from: element) {
        case let .value(value):
            role = value
        case let .unavailable(error):
            return isRetryable(error) ? .retryable(error) : .ineligible(.notEligible)
        }

        guard role != (kAXSheetRole as String) else {
            return .ineligible(.notEligible)
        }
        guard role == (kAXWindowRole as String) else {
            return .ineligible(.notEligible)
        }

        let subrole: String
        switch AXElementAccess.stringAttribute(kAXSubroleAttribute as CFString, from: element) {
        case let .value(value):
            subrole = value
        case let .unavailable(error):
            return isRetryable(error) ? .retryable(error) : .ineligible(.notEligible)
        }

        if subrole == (kAXSystemDialogSubrole as String) {
            return .ineligible(.protectedOrSecureUI)
        }

        if subrole == (kAXDialogSubrole as String) {
            return classifyDialog(element)
        }

        guard subrole == (kAXStandardWindowSubrole as String) else {
            return .ineligible(.notEligible)
        }
        return classifyBrowserWindow(element)
    }

    private static func classifyDialog(_ element: AXUIElement) -> FinderAXWindowClassification {
        switch AXElementAccess.boolAttribute(kAXModalAttribute as CFString, from: element) {
        case let .value(isModal):
            guard isModal else { return .ineligible(.notEligible) }
        case let .unavailable(error):
            return isRetryable(error) ? .retryable(error) : .ineligible(.notEligible)
        }

        let names: Set<String>
        switch AXElementAccess.attributeNames(of: element) {
        case let .value(value):
            names = value
        case let .unavailable(error):
            return isRetryable(error) ? .retryable(error) : .ineligible(.notEligible)
        }

        switch dialogButtonCheck(element, attributeNames: names) {
        case .valid:
            break
        case .invalid:
            return .ineligible(.notEligible)
        case let .retryable(error):
            return .retryable(error)
        }

        switch AXElementAccess.scanForSecureTextFields(in: element) {
        case .clear:
            break
        case .containsSecureField:
            return .ineligible(.protectedOrSecureUI)
        case let .indeterminate(error):
            return isRetryable(error)
                ? .retryable(error)
                : .ineligible(.protectedOrSecureUI)
        }

        switch AXElementAccess.isAttributeSettable(kAXPositionAttribute as CFString, on: element) {
        case let .value(isSettable):
            guard isSettable else { return .ineligible(.unsupportedAttribute) }
        case let .unavailable(error):
            return isRetryable(error) ? .retryable(error) : .ineligible(.unsupportedAttribute)
        }

        switch AXElementAccess.sizeAttribute(kAXSizeAttribute as CFString, from: element) {
        case let .value(size):
            guard size.isUsable else { return .ineligible(.invalidGeometry) }
            return .dialog(size: size)
        case let .unavailable(error):
            return isRetryable(error) ? .retryable(error) : .ineligible(.invalidGeometry)
        }
    }

    private static func classifyBrowserWindow(_ element: AXUIElement) -> FinderAXWindowClassification {
        if case let .value(isModal) = AXElementAccess.boolAttribute(
            kAXModalAttribute as CFString,
            from: element
        ), isModal {
            return .ineligible(.notEligible)
        }
        if case let .value(isMinimized) = AXElementAccess.boolAttribute(
            kAXMinimizedAttribute as CFString,
            from: element
        ), isMinimized {
            return .ineligible(.notEligible)
        }

        let names: Set<String>
        switch AXElementAccess.attributeNames(of: element) {
        case let .value(value):
            names = value
        case let .unavailable(error):
            return isRetryable(error) ? .retryable(error) : .ineligible(.notEligible)
        }

        // Finder browser windows expose a document and all three standard window
        // controls. Requiring these prevents rules from touching Get Info,
        // Settings, progress, and other utility windows without reading titles.
        let requiredNames: Set<String> = [
            kAXDocumentAttribute as String,
            kAXCloseButtonAttribute as String,
            kAXMinimizeButtonAttribute as String,
            kAXZoomButtonAttribute as String,
        ]
        guard requiredNames.isSubset(of: names) else {
            return .ineligible(.notEligible)
        }

        switch AXElementAccess.frame(of: element) {
        case let .value(frame):
            return .browser(frame: frame)
        case let .unavailable(error):
            return isRetryable(error) ? .retryable(error) : .ineligible(.invalidGeometry)
        }
    }

    private static func dialogButtonCheck(
        _ element: AXUIElement,
        attributeNames: Set<String>
    ) -> DialogButtonCheckResult {
        let buttonAttributes: [CFString] = [
            kAXDefaultButtonAttribute as CFString,
            kAXCancelButtonAttribute as CFString,
        ]
        var retryableError: AXError?

        for attribute in buttonAttributes where attributeNames.contains(attribute as String) {
            let button: AXUIElement
            switch AXElementAccess.elementAttribute(attribute, from: element) {
            case let .value(value):
                button = value
            case let .unavailable(error):
                if isRetryable(error) {
                    retryableError = retryableError ?? error
                }
                continue
            }

            switch AXElementAccess.stringAttribute(kAXRoleAttribute as CFString, from: button) {
            case let .value(role):
                if role == (kAXButtonRole as String) {
                    return .valid
                }
            case let .unavailable(error):
                if isRetryable(error) {
                    retryableError = retryableError ?? error
                }
            }
        }

        if let retryableError {
            return .retryable(retryableError)
        }
        return .invalid
    }

    private static func isRetryable(_ error: AXError) -> Bool {
        error == .cannotComplete
    }
}

private extension CGPoint {
    var isFinite: Bool {
        x.isFinite && y.isFinite
    }
}

private extension CGSize {
    var isUsable: Bool {
        width.isFinite && height.isFinite && width > 0 && height > 0
    }
}
