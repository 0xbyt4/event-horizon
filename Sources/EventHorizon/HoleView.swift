import AppKit
import HorizonCore

/// Draws the black hole, its accretion disk and the items in flight.
///
/// The view draws only while something moves. A display link runs during a drag,
/// a fall or an ejection, and stops as soon as everything is still. At rest the
/// window keeps its last frame and the app uses no CPU for drawing.
final class HoleView: NSView {
    private struct Particle {
        let angle: CGFloat
        let distance: CGFloat
        let size: CGFloat
        let brightness: CGFloat
    }

    private struct Flight {
        enum Kind {
            case fall(start: CGVector)
            case eject(target: CGVector)
        }
        let kind: Kind
        let image: CGImage?
        let duration: Double
        /// Negative while the flight waits for its start delay.
        var t: Double
    }

    /// The radius the hole should have. The drawn radius eases toward it.
    var holeRadius: CGFloat = Physics.baseRadius {
        didSet { kick() }
    }

    private var drawnRadius: CGFloat = Physics.baseRadius
    private var energy: CGFloat = 0
    private var energyTarget: CGFloat = 0
    private var dragActive = false
    private var flash: CGFloat = 0
    private var rotation: CGFloat = 0
    private var flights: [Flight] = []
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?

    private static let tilt: CGFloat = 0.3
    private static let iconSize: CGFloat = 48
    private static let diskOuter = NSColor(srgbRed: 0.80, green: 0.47, blue: 0.20, alpha: 1)
    private static let diskInner = NSColor(srgbRed: 1.00, green: 0.74, blue: 0.45, alpha: 1)
    private static let photonRing = NSColor(srgbRed: 1.00, green: 0.86, blue: 0.64, alpha: 1)
    private static let glow = NSColor(srgbRed: 0.93, green: 0.37, blue: 0.43, alpha: 1)
    private static let redshift = NSColor(srgbRed: 0.85, green: 0.20, blue: 0.24, alpha: 1)

    private let particles: [Particle] = {
        var seed: UInt32 = 7
        func next() -> CGFloat {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return CGFloat(seed) / CGFloat(UInt32.max)
        }
        return (0..<170).map { _ in
            Particle(
                angle: next() * .pi * 2,
                distance: 1.5 + pow(next(), 1.7) * 2.3,
                size: 0.7 + next() * 1.3,
                brightness: 0.3 + next() * 0.7
            )
        }
    }()

    override var isOpaque: Bool { false }

    // MARK: - Events from the controller

    /// Updates the pull while the user drags files. `pull` is 0...1.
    func setDrag(active: Bool, pull: CGFloat) {
        dragActive = active
        energyTarget = active ? pull : 0
        kick()
    }

    /// Starts a fall from `start` (offset from the center) after `delay` seconds.
    func addFall(image: NSImage, from start: CGVector, duration: Double, delay: Double) {
        flights.append(Flight(kind: .fall(start: start), image: cgImage(image), duration: duration, t: -delay / duration))
        kick()
    }

    /// Throws an item out of the hole toward `target` (offset from the center).
    func addEject(image: NSImage, toward target: CGVector) {
        flights.append(Flight(kind: .eject(target: target), image: cgImage(image), duration: 0.8, t: 0))
        flash = max(flash, 0.8)
        kick()
    }

    private func cgImage(_ image: NSImage) -> CGImage? {
        var rect = CGRect(x: 0, y: 0, width: Self.iconSize * 2, height: Self.iconSize * 2)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    // MARK: - Frame loop

    private func kick() {
        guard displayLink == nil, window != nil else {
            needsDisplay = true
            return
        }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTimestamp = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let dt = min(0.05, lastTimestamp.map { link.timestamp - $0 } ?? 1.0 / 60)
        lastTimestamp = link.timestamp
        let busy = step(dt)
        needsDisplay = true
        if !busy {
            link.invalidate()
            displayLink = nil
        }
    }

    private func step(_ dt: Double) -> Bool {
        var busy = dragActive
        var target = energyTarget

        drawnRadius += (holeRadius - drawnRadius) * min(1, CGFloat(dt) * 5)
        if abs(holeRadius - drawnRadius) > 0.05 {
            busy = true
        } else {
            drawnRadius = holeRadius
        }

        var finished = false
        for index in flights.indices {
            flights[index].t += dt / flights[index].duration
            if flights[index].t >= 0 { target = 1 }
            if flights[index].t >= 1 {
                finished = true
                if case .fall = flights[index].kind { flash = 1 }
            }
        }
        if finished { flights.removeAll { $0.t >= 1 } }
        if !flights.isEmpty { busy = true }

        let rate: CGFloat = target > energy ? 8 : 5
        energy += (target - energy) * min(1, CGFloat(dt) * rate)
        if energy < 0.02 && target == 0 { energy = 0 }
        if energy > 0 { busy = true }

        flash = max(0, flash - CGFloat(dt) * 2.5)
        if flash > 0 { busy = true }

        if busy && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            rotation += CGFloat(dt) * (0.25 + energy * 2.4)
        }
        return busy
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let r = drawnRadius

        drawGlow(context, center, r)
        if dragActive && energy > 0.04 { drawCaptureRing(context, center, r) }
        drawDisk(context, center, r, front: false)
        drawLensedArc(context, center, r)

        context.setFillColor(NSColor.black.cgColor)
        context.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        context.setStrokeColor(Self.photonRing.withAlphaComponent(0.85).cgColor)
        context.setLineWidth(1.2)
        context.strokeEllipse(in: CGRect(x: center.x - r * 1.07, y: center.y - r * 1.07, width: r * 2.14, height: r * 2.14))

        drawDisk(context, center, r, front: true)
        for flight in flights where flight.t >= 0 { drawFlight(context, center, r, flight) }
    }

    private func drawGlow(_ context: CGContext, _ center: CGPoint, _ r: CGFloat) {
        let strength = min(1, energy * 0.8 + flash * 0.6)
        guard strength > 0.01 else { return }
        let colors = [
            Self.glow.withAlphaComponent(0.28 * strength).cgColor,
            Self.glow.withAlphaComponent(0).cgColor,
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) else { return }
        context.drawRadialGradient(gradient, startCenter: center, startRadius: r * 0.8, endCenter: center, endRadius: r * 6, options: [])
    }

    private func drawCaptureRing(_ context: CGContext, _ center: CGPoint, _ r: CGFloat) {
        let capture = Physics.captureRadius(r)
        context.saveGState()
        context.setLineDash(phase: 0, lengths: [2, 5])
        context.setLineWidth(1)
        context.setStrokeColor(Self.photonRing.withAlphaComponent(min(1, energy * 1.4) * 0.8).cgColor)
        context.strokeEllipse(in: CGRect(x: center.x - capture, y: center.y - capture, width: capture * 2, height: capture * 2))
        context.restoreGState()
    }

    /// The far half of the disk sits above the center (y up); the near half sits below and covers the horizon.
    private func drawDisk(_ context: CGContext, _ center: CGPoint, _ r: CGFloat, front: Bool) {
        for particle in particles {
            let angle = particle.angle + rotation * pow(1.5 / particle.distance, 1.5) * 2
            let s = sin(angle)
            if front ? s > 0 : s <= 0 { continue }
            let x = center.x + cos(angle) * particle.distance * r
            let y = center.y + s * particle.distance * r * Self.tilt
            let inner = min(1, max(0, (2.6 - particle.distance) / 1.1))
            let color = Self.diskOuter.blended(withFraction: inner * (0.45 + 0.5 * energy), of: Self.diskInner) ?? Self.diskOuter
            let alpha = min(1, particle.brightness * (0.65 + 0.45 * energy))
            context.setFillColor(color.withAlphaComponent(alpha).cgColor)
            let size = particle.size * (r / 22) * (front ? 1.1 : 0.9)
            context.fill(CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size))
        }
    }

    /// The far side of the disk, bent over the top of the hole by lensing.
    private func drawLensedArc(_ context: CGContext, _ center: CGPoint, _ r: CGFloat) {
        let path = CGMutablePath()
        let transform = CGAffineTransform(translationX: center.x, y: center.y).scaledBy(x: r * 1.75, y: r * 1.32)
        path.addArc(center: .zero, radius: 1, startAngle: .pi * 0.04, endAngle: .pi * 0.96, clockwise: false, transform: transform)
        context.addPath(path)
        context.setStrokeColor(Self.diskOuter.withAlphaComponent(0.4 + 0.3 * energy).cgColor)
        context.setLineWidth(max(1, r * 0.14))
        context.strokePath()
    }

    private func drawFlight(_ context: CGContext, _ center: CGPoint, _ r: CGFloat, _ flight: Flight) {
        let t = CGFloat(min(1, flight.t))
        let pose: Physics.Pose
        switch flight.kind {
        case .fall(let start): pose = Physics.fall(t: t, start: start, radius: r)
        case .eject(let target): pose = Physics.eject(t: t, target: target)
        }
        guard pose.alpha > 0.01, let image = flight.image else { return }

        context.saveGState()
        context.setAlpha(pose.alpha)
        context.translateBy(x: center.x + pose.offset.dx, y: center.y + pose.offset.dy)
        if pose.stretch != 1 {
            context.rotate(by: pose.direction)
            context.scaleBy(x: pose.stretch, y: 1 / sqrt(pose.stretch))
            context.rotate(by: -pose.direction)
        }
        context.scaleBy(x: pose.scale, y: pose.scale)
        let size = Self.iconSize
        let rect = CGRect(x: -size / 2, y: -size / 2, width: size, height: size)
        context.draw(image, in: rect)
        if pose.heat > 0.01 {
            // Red-shift: tint the icon's own shape.
            context.clip(to: rect, mask: image)
            context.setFillColor(Self.redshift.withAlphaComponent(pose.heat * 0.7).cgColor)
            context.fill(rect)
        }
        context.restoreGState()
    }
}
