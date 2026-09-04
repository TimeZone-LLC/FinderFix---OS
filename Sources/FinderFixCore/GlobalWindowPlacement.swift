import CoreGraphics
import Foundation

public struct GlobalWindowPlacementSettings: Codable, Hashable, Sendable {
    public static let maximumExcludedApplications: Int = 128
    public static let supportedCoverageRange: ClosedRange<Double> = 0.40...0.95
    public static let supportedAspectComponentRange: ClosedRange<Double> = 1...100

    public var isEnabled: Bool
    public var aspectRatioWidth: Double
    public var aspectRatioHeight: Double
    /// The maximum fraction of both dimensions of the primary display's visible frame.
    public var screenCoverage: Double
    public var excludedApplicationBundleIdentifiers: [String]

    public init(
        isEnabled: Bool = false,
        aspectRatioWidth: Double = 16,
        aspectRatioHeight: Double = 10,
        screenCoverage: Double = 0.80,
        excludedApplicationBundleIdentifiers: [String] = []
    ) {
        self.isEnabled = isEnabled
        self.aspectRatioWidth = aspectRatioWidth
        self.aspectRatioHeight = aspectRatioHeight
        self.screenCoverage = screenCoverage
        self.excludedApplicationBundleIdentifiers = excludedApplicationBundleIdentifiers
    }

    public static let defaults: GlobalWindowPlacementSettings = GlobalWindowPlacementSettings()

    public func normalized() -> GlobalWindowPlacementSettings {
        var value: GlobalWindowPlacementSettings = self
        value.aspectRatioWidth = Self.clampedFinite(
            aspectRatioWidth,
            range: Self.supportedAspectComponentRange,
            fallback: Self.defaults.aspectRatioWidth
        )
        value.aspectRatioHeight = Self.clampedFinite(
            aspectRatioHeight,
            range: Self.supportedAspectComponentRange,
            fallback: Self.defaults.aspectRatioHeight
        )
        value.screenCoverage = Self.clampedFinite(
            screenCoverage,
            range: Self.supportedCoverageRange,
            fallback: Self.defaults.screenCoverage
        )

        var seenIdentifiers: Set<String> = []
        var identifiers: [String] = []
        for identifier in excludedApplicationBundleIdentifiers.prefix(
            Self.maximumExcludedApplications
        ) {
            let trimmedIdentifier: String = String(
                identifier.trimmingCharacters(in: .whitespacesAndNewlines).prefix(255)
            )
            guard !trimmedIdentifier.isEmpty else { continue }
            let comparisonIdentifier: String = trimmedIdentifier.lowercased()
            guard seenIdentifiers.insert(comparisonIdentifier).inserted else { continue }
            identifiers.append(trimmedIdentifier)
        }
        value.excludedApplicationBundleIdentifiers = identifiers
        return value
    }

    private static func clampedFinite(
        _ value: Double,
        range: ClosedRange<Double>,
        fallback: Double
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

public struct GlobalWindowPlacementPlan: Equatable, Sendable {
    public let targetFrameInAppKit: CGRect
    public let targetTopLeftInAX: CGPoint

    public init(targetFrameInAppKit: CGRect, targetTopLeftInAX: CGPoint) {
        self.targetFrameInAppKit = targetFrameInAppKit
        self.targetTopLeftInAX = targetTopLeftInAX
    }
}

public enum GlobalWindowPlacementGeometry {
    public static func plan(
        settings: GlobalWindowPlacementSettings,
        primaryDisplayFrameInAppKit: CGRect,
        primaryVisibleFrameInAppKit: CGRect
    ) -> GlobalWindowPlacementPlan? {
        let settings: GlobalWindowPlacementSettings = settings.normalized()
        guard primaryDisplayFrameInAppKit.isFiniteAndPositive,
              primaryVisibleFrameInAppKit.isFiniteAndPositive else {
            return nil
        }

        let aspectRatio: CGFloat = CGFloat(
            settings.aspectRatioWidth / settings.aspectRatioHeight
        )
        let maximumSize: CGSize = CGSize(
            width: primaryVisibleFrameInAppKit.width * settings.screenCoverage,
            height: primaryVisibleFrameInAppKit.height * settings.screenCoverage
        )
        guard aspectRatio.isFinite,
              aspectRatio > 0,
              maximumSize.isFiniteAndPositive else {
            return nil
        }

        let targetSize: CGSize
        if maximumSize.width / maximumSize.height > aspectRatio {
            targetSize = CGSize(
                width: maximumSize.height * aspectRatio,
                height: maximumSize.height
            )
        } else {
            targetSize = CGSize(
                width: maximumSize.width,
                height: maximumSize.width / aspectRatio
            )
        }

        let targetFrame: CGRect = CGRect(
            x: primaryVisibleFrameInAppKit.midX - (targetSize.width / 2),
            y: primaryVisibleFrameInAppKit.midY - (targetSize.height / 2),
            width: targetSize.width,
            height: targetSize.height
        )
        guard let targetTopLeft: CGPoint = PlacementGeometry.axTopLeft(
            forAppKitFrame: targetFrame,
            primaryDisplayFrameInAppKit: primaryDisplayFrameInAppKit
        ) else {
            return nil
        }
        return GlobalWindowPlacementPlan(
            targetFrameInAppKit: targetFrame,
            targetTopLeftInAX: targetTopLeft
        )
    }
}

private extension CGSize {
    var isFiniteAndPositive: Bool {
        width.isFinite && height.isFinite && width > 0 && height > 0
    }
}

private extension CGRect {
    var isFiniteAndPositive: Bool {
        origin.x.isFinite
            && origin.y.isFinite
            && maxX.isFinite
            && maxY.isFinite
            && size.isFiniteAndPositive
            && !isInfinite
            && !isNull
    }
}
