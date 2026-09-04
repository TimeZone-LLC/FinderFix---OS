import CoreGraphics
import Foundation

public struct DisplayGeometry: Codable, Hashable, Sendable, Identifiable {
    public let identifier: UInt32
    public let frameInAppKit: CGRect
    public let visibleFrameInAppKit: CGRect
    public let isPrimary: Bool

    public var id: UInt32 {
        identifier
    }

    public init(
        identifier: UInt32,
        frameInAppKit: CGRect,
        visibleFrameInAppKit: CGRect,
        isPrimary: Bool
    ) {
        self.identifier = identifier
        self.frameInAppKit = frameInAppKit
        self.visibleFrameInAppKit = visibleFrameInAppKit
        self.isPrimary = isPrimary
    }

    public var isUsable: Bool {
        PlacementGeometry.isUsable(frameInAppKit)
            && PlacementGeometry.isUsable(visibleFrameInAppKit)
    }
}

public struct WindowGeometry: Codable, Hashable, Sendable {
    public let topLeftInAX: CGPoint
    public let size: CGSize

    public init(topLeftInAX: CGPoint, size: CGSize) {
        self.topLeftInAX = topLeftInAX
        self.size = size
    }

    public func appKitFrame(primaryDisplayFrameInAppKit: CGRect) -> CGRect? {
        PlacementGeometry.appKitFrame(
            fromAXTopLeft: topLeftInAX,
            windowSize: size,
            primaryDisplayFrameInAppKit: primaryDisplayFrameInAppKit
        )
    }
}

/// Pure coordinate and placement calculations. AppKit uses a bottom-left
/// global origin while Accessibility uses a top-left global origin.
public enum PlacementGeometry {
    public static func centeredAXTopLeft(
        windowSize: CGSize,
        targetVisibleFrameInAppKit: CGRect,
        primaryDisplayFrameInAppKit: CGRect
    ) -> CGPoint? {
        axTopLeft(
            windowSize: windowSize,
            placement: .centered,
            targetVisibleFrameInAppKit: targetVisibleFrameInAppKit,
            primaryDisplayFrameInAppKit: primaryDisplayFrameInAppKit,
            constrainToVisibleFrame: true
        )
    }

    public static func axTopLeft(
        windowSize: CGSize,
        placement: WindowPlacement,
        targetVisibleFrameInAppKit: CGRect,
        primaryDisplayFrameInAppKit: CGRect,
        constrainToVisibleFrame: Bool
    ) -> CGPoint? {
        guard isUsable(windowSize),
              isUsable(targetVisibleFrameInAppKit),
              isUsable(primaryDisplayFrameInAppKit) else {
            return nil
        }

        let desiredFrame: CGRect
        switch placement {
        case .centered:
            desiredFrame = CGRect(
                x: targetVisibleFrameInAppKit.midX - (windowSize.width / 2),
                y: targetVisibleFrameInAppKit.midY - (windowSize.height / 2),
                width: windowSize.width,
                height: windowSize.height
            )
        case let .topLeftOffset(x, y):
            guard x.isFinite, y.isFinite else {
                return nil
            }
            desiredFrame = CGRect(
                x: targetVisibleFrameInAppKit.minX + x,
                y: targetVisibleFrameInAppKit.maxY - y - windowSize.height,
                width: windowSize.width,
                height: windowSize.height
            )
        }

        let placedFrame: CGRect
        if constrainToVisibleFrame {
            guard let clampedFrame: CGRect = clampedAppKitFrame(
                desiredFrame,
                toVisibleFrame: targetVisibleFrameInAppKit
            ) else {
                return nil
            }
            placedFrame = clampedFrame
        } else {
            placedFrame = desiredFrame
        }

        return axTopLeft(
            forAppKitFrame: placedFrame,
            primaryDisplayFrameInAppKit: primaryDisplayFrameInAppKit
        )
    }

    /// Constrains a window to the visible frame. If the window is larger than
    /// the available area, its top-leading corner remains accessible.
    public static func clampedAppKitFrame(
        _ frame: CGRect,
        toVisibleFrame visibleFrame: CGRect
    ) -> CGRect? {
        guard isUsable(frame), isUsable(visibleFrame) else {
            return nil
        }

        let x: CGFloat
        if frame.width <= visibleFrame.width {
            x = clamped(
                frame.minX,
                minimum: visibleFrame.minX,
                maximum: visibleFrame.maxX - frame.width
            )
        } else {
            x = visibleFrame.minX
        }

        let y: CGFloat
        if frame.height <= visibleFrame.height {
            y = clamped(
                frame.minY,
                minimum: visibleFrame.minY,
                maximum: visibleFrame.maxY - frame.height
            )
        } else {
            y = visibleFrame.maxY - frame.height
        }

        return CGRect(origin: CGPoint(x: x, y: y), size: frame.size)
    }

    public static func axTopLeft(
        forAppKitFrame frame: CGRect,
        primaryDisplayFrameInAppKit: CGRect
    ) -> CGPoint? {
        guard isUsable(frame), isUsable(primaryDisplayFrameInAppKit) else {
            return nil
        }
        return CGPoint(
            x: frame.minX,
            y: primaryDisplayFrameInAppKit.maxY - frame.maxY
        )
    }

    public static func appKitFrame(
        fromAXTopLeft topLeft: CGPoint,
        windowSize: CGSize,
        primaryDisplayFrameInAppKit: CGRect
    ) -> CGRect? {
        guard topLeft.x.isFinite,
              topLeft.y.isFinite,
              isUsable(windowSize),
              isUsable(primaryDisplayFrameInAppKit) else {
            return nil
        }
        return CGRect(
            x: topLeft.x,
            y: primaryDisplayFrameInAppKit.maxY - topLeft.y - windowSize.height,
            width: windowSize.width,
            height: windowSize.height
        )
    }

    static func isUsable(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    static func isUsable(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.maxX.isFinite
            && rect.maxY.isFinite
            && isUsable(rect.size)
            && !rect.isInfinite
            && !rect.isNull
    }

    private static func clamped(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(value, minimum), maximum)
    }
}
