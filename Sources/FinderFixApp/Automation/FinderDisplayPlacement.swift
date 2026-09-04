import AppKit
import CoreGraphics
import FinderFixCore
import Foundation

@MainActor
enum FinderDisplayPlacement {
    /// A full-display frame is sufficient evidence that geometry is managed by
    /// fullscreen. macOS exposes no public AX tile/fullscreen state attribute,
    /// so other layouts are left to the AX settable checks instead of guessing.
    static func matchesEntireDisplay(
        frameInAX: CGRect,
        tolerance: CGFloat = 2
    ) -> Bool {
        guard tolerance.isFinite,
              tolerance >= 0,
              let primaryScreen: NSScreen = NSScreen.screens.first,
              let appKitFrame: CGRect = PlacementGeometry.appKitFrame(
                  fromAXTopLeft: frameInAX.origin,
                  windowSize: frameInAX.size,
                  primaryDisplayFrameInAppKit: primaryScreen.frame
              ) else {
            return false
        }

        return NSScreen.screens.contains { screen in
            abs(appKitFrame.minX - screen.frame.minX) <= tolerance
                && abs(appKitFrame.minY - screen.frame.minY) <= tolerance
                && abs(appKitFrame.width - screen.frame.width) <= tolerance
                && abs(appKitFrame.height - screen.frame.height) <= tolerance
        }
    }

    static func centeredDialogTopLeft(size: CGSize) -> CGPoint? {
        guard let primaryScreen: NSScreen = NSScreen.screens.first else { return nil }
        return PlacementGeometry.centeredAXTopLeft(
            windowSize: size,
            targetVisibleFrameInAppKit: primaryScreen.visibleFrame,
            primaryDisplayFrameInAppKit: primaryScreen.frame
        )
    }

    static func normalWindowTopLeft(
        currentFrameInAX: CGRect,
        targetSize: CGSize,
        configuration: FinderWindowRuleConfiguration
    ) -> CGPoint? {
        guard let primaryScreen: NSScreen = NSScreen.screens.first,
              let targetScreen: NSScreen = targetScreen(
                  for: configuration.display,
                  currentFrameInAX: currentFrameInAX,
                  primaryScreen: primaryScreen
              ) else {
            return nil
        }

        switch configuration.position {
        case .unchanged:
            return currentFrameInAX.origin
        case .centered:
            return PlacementGeometry.axTopLeft(
                windowSize: targetSize,
                placement: .centered,
                targetVisibleFrameInAppKit: targetScreen.visibleFrame,
                primaryDisplayFrameInAppKit: primaryScreen.frame,
                constrainToVisibleFrame: configuration.constrainToVisibleFrame
            )
        case let .topLeft(inset):
            return anchoredTopLeft(
                size: targetSize,
                horizontal: .leading(inset),
                vertical: .top(inset),
                targetScreen: targetScreen,
                primaryScreen: primaryScreen,
                constrain: configuration.constrainToVisibleFrame
            )
        case let .topRight(inset):
            return anchoredTopLeft(
                size: targetSize,
                horizontal: .trailing(inset),
                vertical: .top(inset),
                targetScreen: targetScreen,
                primaryScreen: primaryScreen,
                constrain: configuration.constrainToVisibleFrame
            )
        case let .bottomLeft(inset):
            return anchoredTopLeft(
                size: targetSize,
                horizontal: .leading(inset),
                vertical: .bottom(inset),
                targetScreen: targetScreen,
                primaryScreen: primaryScreen,
                constrain: configuration.constrainToVisibleFrame
            )
        case let .bottomRight(inset):
            return anchoredTopLeft(
                size: targetSize,
                horizontal: .trailing(inset),
                vertical: .bottom(inset),
                targetScreen: targetScreen,
                primaryScreen: primaryScreen,
                constrain: configuration.constrainToVisibleFrame
            )
        case let .topLeftOffset(x, y):
            return PlacementGeometry.axTopLeft(
                windowSize: targetSize,
                placement: .topLeftOffset(x: x, y: y),
                targetVisibleFrameInAppKit: targetScreen.visibleFrame,
                primaryDisplayFrameInAppKit: primaryScreen.frame,
                constrainToVisibleFrame: configuration.constrainToVisibleFrame
            )
        }
    }

    private static func targetScreen(
        for target: FinderWindowDisplayTarget,
        currentFrameInAX: CGRect,
        primaryScreen: NSScreen
    ) -> NSScreen? {
        let screens: [NSScreen] = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        switch target {
        case .primary:
            return primaryScreen
        case .pointer:
            let pointerLocation: CGPoint = NSEvent.mouseLocation
            return screens.first(where: { NSPointInRect(pointerLocation, $0.frame) }) ?? primaryScreen
        case .currentWindow:
            guard let appKitFrame: CGRect = PlacementGeometry.appKitFrame(
                fromAXTopLeft: currentFrameInAX.origin,
                windowSize: currentFrameInAX.size,
                primaryDisplayFrameInAppKit: primaryScreen.frame
            ) else {
                return primaryScreen
            }

            return screens.max { lhs, rhs in
                intersectionArea(appKitFrame, lhs.frame) < intersectionArea(appKitFrame, rhs.frame)
            } ?? primaryScreen
        }
    }

    private enum HorizontalAnchor {
        case leading(CGFloat)
        case trailing(CGFloat)
    }

    private enum VerticalAnchor {
        case top(CGFloat)
        case bottom(CGFloat)
    }

    private static func anchoredTopLeft(
        size: CGSize,
        horizontal: HorizontalAnchor,
        vertical: VerticalAnchor,
        targetScreen: NSScreen,
        primaryScreen: NSScreen,
        constrain: Bool
    ) -> CGPoint? {
        guard size.isUsable else { return nil }
        let visibleFrame: CGRect = targetScreen.visibleFrame

        let x: CGFloat
        switch horizontal {
        case let .leading(inset):
            guard inset.isFinite else { return nil }
            x = visibleFrame.minX + max(0, inset)
        case let .trailing(inset):
            guard inset.isFinite else { return nil }
            x = visibleFrame.maxX - max(0, inset) - size.width
        }

        let y: CGFloat
        switch vertical {
        case let .top(inset):
            guard inset.isFinite else { return nil }
            y = visibleFrame.maxY - max(0, inset) - size.height
        case let .bottom(inset):
            guard inset.isFinite else { return nil }
            y = visibleFrame.minY + max(0, inset)
        }

        let desiredFrame: CGRect = CGRect(origin: CGPoint(x: x, y: y), size: size)
        let placedFrame: CGRect
        if constrain {
            guard let clamped: CGRect = PlacementGeometry.clampedAppKitFrame(
                desiredFrame,
                toVisibleFrame: visibleFrame
            ) else {
                return nil
            }
            placedFrame = clamped
        } else {
            placedFrame = desiredFrame
        }

        return PlacementGeometry.axTopLeft(
            forAppKitFrame: placedFrame,
            primaryDisplayFrameInAppKit: primaryScreen.frame
        )
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection: CGRect = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }
}

private extension CGSize {
    var isUsable: Bool {
        width.isFinite && height.isFinite && width > 0 && height > 0
    }
}
