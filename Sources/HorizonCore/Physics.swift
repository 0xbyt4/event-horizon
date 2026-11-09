import CoreGraphics
import Foundation

/// Geometry and motion of the black hole and the items that fall into it.
/// All values are in screen points. Offsets are relative to the hole center, y points up.
public enum Physics {
    /// Radius of the event horizon when the hole has no mass.
    public static let baseRadius: CGFloat = 22

    /// The largest growth over `baseRadius`, as a fraction.
    private static let maxGrowth: CGFloat = 0.8

    /// The largest radius `radius(items:bytes:)` can return.
    public static let maxRadius: CGFloat = baseRadius * (1 + maxGrowth)

    /// The hole grows with each item it holds and with their total size.
    ///
    /// Each item adds a visible step, and the steps get smaller as the count grows:
    /// 1 item adds 8 %, 7 items add 24 %, 31 items add 40 %. Size adds up to 40 % more
    /// on a log scale, so a 1 GB archive weighs more than a small text file.
    public static func radius(items: Int, bytes: Int64) -> CGFloat {
        let countGrowth = 0.08 * log2(1 + Double(max(0, items)))
        let megabytes = Double(max(0, bytes)) / 1_000_000
        let sizeGrowth = 0.1 * min(4, log10(1 + megabytes))
        return baseRadius * (1 + min(maxGrowth, CGFloat(countGrowth + sizeGrowth)))
    }

    /// Items released inside this distance from the center fall in.
    public static func captureRadius(_ radius: CGFloat) -> CGFloat { radius * 2.6 }

    /// A dragged item starts to feel the pull inside this distance.
    public static func influenceRadius(_ radius: CGFloat) -> CGFloat { radius * 7 }

    /// How far from the center an item flies when the hole throws it back out.
    public static func ejectDistance(_ radius: CGFloat) -> CGFloat { radius * 4.4 }

    /// Pull strength: 0 at the influence radius and beyond, 1 at the center.
    public static func pull(distance: CGFloat, radius: CGFloat) -> CGFloat {
        clamp(1 - distance / influenceRadius(radius))
    }

    /// Time for an item to fall in. Bigger items fall slower.
    public static func fallDuration(bytes: Int64) -> Double {
        0.85 + 0.12 * log10(1 + Double(max(0, bytes)) / 1_000_000)
    }

    /// How an item looks at one moment of its flight.
    public struct Pose: Equatable {
        public var offset: CGVector
        /// Stretch along `direction` (spaghettification). 1 means no stretch.
        public var stretch: CGFloat
        public var scale: CGFloat
        public var alpha: CGFloat
        /// 0 is the normal color, 1 is fully red-shifted.
        public var heat: CGFloat
        /// Angle of the stretch axis, in radians.
        public var direction: CGFloat
    }

    /// An item that spirals from `start` into the horizon. `t` runs from 0 to 1.
    public static func fall(t rawT: CGFloat, start: CGVector, radius: CGFloat) -> Pose {
        let t = clamp(rawT)
        let e = t * t
        let startDistance = max(radius * 1.2, hypot(start.dx, start.dy))
        let startAngle = atan2(start.dy, start.dx)
        let distance = startDistance * (1 - e)
        let angle = startAngle + (1 - (1 - t) * (1 - t)) * .pi * 2.4
        return Pose(
            offset: CGVector(dx: cos(angle) * distance, dy: sin(angle) * distance * (1 - 0.45 * t)),
            stretch: 1 + 3 * e,
            scale: 1 - 0.55 * e,
            alpha: 1 - smoothstep(0.65, 1, t),
            heat: min(1, t * 1.4),
            direction: angle + .pi
        )
    }

    /// An item that the hole throws back out toward `target`, then fades.
    public static func eject(t rawT: CGFloat, target: CGVector) -> Pose {
        let t = clamp(rawT)
        let e = 1 - pow(1 - t, 3)
        let targetAngle = atan2(target.dy, target.dx)
        let angle = targetAngle - (1 - e) * .pi * 1.6
        let distance = hypot(target.dx, target.dy) * e
        return Pose(
            offset: CGVector(dx: cos(angle) * distance, dy: sin(angle) * distance),
            stretch: 1 + 2 * (1 - e),
            scale: 0.45 + 0.55 * e,
            alpha: min(1, t * 3) * (1 - smoothstep(0.75, 1, t)),
            heat: 1 - e,
            direction: angle + .pi
        )
    }

    static func clamp(_ value: CGFloat, _ low: CGFloat = 0, _ high: CGFloat = 1) -> CGFloat {
        min(high, max(low, value))
    }

    static func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = clamp((x - edge0) / (edge1 - edge0))
        return t * t * (3 - 2 * t)
    }
}
