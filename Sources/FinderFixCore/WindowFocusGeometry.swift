import CoreGraphics
import Foundation

public enum WindowFocusGeometry {
    public static func shouldSuspendForOwnInterface(
        applicationIsActive: Bool,
        pointerPositionInAX: WindowFocusPointerPosition,
        primaryDisplayFrameInAppKit: CGRect,
        visibleWindowFramesInAppKit: [CGRect]
    ) -> Bool {
        guard pointerPositionInAX.x.isFinite,
              pointerPositionInAX.y.isFinite,
              primaryDisplayFrameInAppKit.isFiniteAndPositive else {
            return true
        }

        let visibleWindowFrames: [CGRect] = visibleWindowFramesInAppKit.filter {
            $0.isFiniteAndPositive
        }
        guard !applicationIsActive || !visibleWindowFrames.isEmpty else {
            return true
        }

        let pointerPositionInAppKit: CGPoint = CGPoint(
            x: pointerPositionInAX.x,
            y: primaryDisplayFrameInAppKit.maxY - pointerPositionInAX.y
        )
        return visibleWindowFrames.contains { windowFrame in
            windowFrame.contains(pointerPositionInAppKit)
        }
    }

    public static func hasMinimumVisibleIntersection(
        windowFrame: CGRect,
        screenFrame: CGRect,
        minimumDimension: CGFloat = 4
    ) -> Bool {
        guard windowFrame.isFiniteAndPositive,
              screenFrame.isFiniteAndPositive,
              minimumDimension.isFinite,
              minimumDimension > 0 else {
            return false
        }

        let intersection: CGRect = windowFrame.intersection(screenFrame)
        return !intersection.isNull
            && !intersection.isEmpty
            && intersection.width >= minimumDimension
            && intersection.height >= minimumDimension
    }
}

private extension CGRect {
    var isFiniteAndPositive: Bool {
        origin.x.isFinite
            && origin.y.isFinite
            && width.isFinite
            && height.isFinite
            && width > 0
            && height > 0
    }
}
