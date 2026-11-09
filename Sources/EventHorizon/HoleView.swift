import AppKit
import HorizonCore

/// Draws the black hole, its accretion disk and the items in flight.
///
/// The view draws only while something moves. A display link runs during a drag,
/// a fall or an ejection, and stops as soon as everything is still. At rest the
/// window keeps its last frame and the app uses no CPU for drawing.
///
/// The disk is two textures drawn once at startup: an inner and an outer ring, seen face-on.
/// Each frame rotates and squashes them, so a frame costs a few image draws.
final class HoleView: NSView {
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
    /// Reused buffer for the disk layers. Blend modes inside a transparency layer of the
    /// window context make Core Graphics allocate a buffer as large as the whole window.
    private var diskBuffer: CGContext?

    private static let iconSize: CGFloat = 48
    private static let photonRing = NSColor(srgbRed: 1.00, green: 0.86, blue: 0.64, alpha: 1)
    private static let redshift = NSColor(srgbRed: 0.85, green: 0.20, blue: 0.24, alpha: 1)

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
        let r = drawnRadius
        // The near side of the disk moves to the right, toward the viewer.
        let spin = -rotation
        let glow = min(1, energy * 0.8 + flash * 0.6)
        let lift = 0.2 * energy + 0.25 * flash

        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.interpolationQuality = .medium

        drawScatteredLight(context, r, glow)
        if dragActive && energy > 0.04 { drawCaptureRing(context, r) }

        // The lensed halo and the far half of the disk sit behind the shadow.
        drawLayer(into: context, r) { layer in
            Disk.drawHalo(layer, r, spin)
            Disk.drawHalf(layer, r, front: false, spin)
            Disk.applyDoppler(layer, r, lift: lift)
        }

        context.setFillColor(NSColor.black.cgColor)
        context.fillEllipse(in: CGRect(x: -r, y: -r, width: r * 2, height: r * 2))
        Disk.drawPhotonRing(context, r)

        // The near half of the disk crosses in front of the shadow.
        drawLayer(into: context, r) { layer in
            Disk.drawHalf(layer, r, front: true, spin)
            Disk.applyDoppler(layer, r, lift: lift)
        }

        for flight in flights where flight.t >= 0 { drawFlight(context, r, flight) }
        context.restoreGState()

        // At rest the window keeps this frame, so the buffer is not needed until the next animation.
        if displayLink == nil { diskBuffer = nil }
    }

    /// Draws `body` into the reused disk buffer, then draws the buffer centered on the hole.
    /// The buffer size grows in steps of 64 pixels, so a growing hole does not reallocate it every frame.
    private func drawLayer(into context: CGContext, _ r: CGFloat, _ body: (CGContext) -> Void) {
        let scale = window?.backingScaleFactor ?? 2
        let needed = Int((Disk.layerSide(max(r, holeRadius)) * scale).rounded(.up))
        let pixels = (needed + 63) / 64 * 64
        if diskBuffer?.width != pixels {
            diskBuffer = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: Disk.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            diskBuffer?.interpolationQuality = .medium
        }
        guard let layer = diskBuffer else { return }
        layer.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        layer.saveGState()
        layer.translateBy(x: CGFloat(pixels) / 2, y: CGFloat(pixels) / 2)
        layer.scaleBy(x: scale, y: scale)
        body(layer)
        layer.restoreGState()
        guard let image = layer.makeImage() else { return }
        let drawn = CGFloat(pixels) / scale
        context.draw(image, in: CGRect(x: -drawn / 2, y: -drawn / 2, width: drawn, height: drawn))
    }

    private func drawScatteredLight(_ context: CGContext, _ r: CGFloat, _ glow: CGFloat) {
        let alpha = 0.1 + 0.22 * glow
        let colors = [
            CGColor(srgbRed: 1.0, green: 0.67, blue: 0.37, alpha: alpha),
            CGColor(srgbRed: 1.0, green: 0.67, blue: 0.37, alpha: 0),
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: Disk.colorSpace, colors: colors, locations: [0, 1]) else { return }
        context.drawRadialGradient(gradient, startCenter: .zero, startRadius: r, endCenter: .zero, endRadius: r * 5, options: [])
    }

    private func drawCaptureRing(_ context: CGContext, _ r: CGFloat) {
        let capture = Physics.captureRadius(r)
        context.saveGState()
        context.setLineDash(phase: 0, lengths: [2, 5])
        context.setLineWidth(1)
        context.setStrokeColor(Self.photonRing.withAlphaComponent(min(1, energy * 1.4) * 0.8).cgColor)
        context.strokeEllipse(in: CGRect(x: -capture, y: -capture, width: capture * 2, height: capture * 2))
        context.restoreGState()
    }

    private func drawFlight(_ context: CGContext, _ r: CGFloat, _ flight: Flight) {
        let t = CGFloat(min(1, flight.t))
        let pose: Physics.Pose
        switch flight.kind {
        case .fall(let start): pose = Physics.fall(t: t, start: start, radius: r)
        case .eject(let target): pose = Physics.eject(t: t, target: target)
        }
        guard pose.alpha > 0.01, let image = flight.image else { return }

        context.saveGState()
        context.setAlpha(pose.alpha)
        context.translateBy(x: pose.offset.dx, y: pose.offset.dy)
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

/// The accretion disk: thin, almost edge-on, with light from its far side bent around the shadow.
/// Lengths are in units of the shadow radius `r`. The context origin is the hole center, y up.
private enum Disk {
    static let inner: CGFloat = 1.12
    static let middle: CGFloat = 2.2
    static let outer: CGFloat = 4.3
    /// How flat the disk looks. 0 is edge-on, 1 is face-on.
    static let tilt: CGFloat = 0.12
    /// Pixels per unit of `r` in the textures.
    static let textureScale: CGFloat = 56

    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Inner ring turns faster than the outer ring, like an orbit.
    static let rings: [(image: CGImage?, speed: CGFloat)] = [
        (makeTexture(from: middle, to: outer, seed: 23, streaks: 420), 1),
        (makeTexture(from: inner, to: middle, seed: 11, streaks: 520), 1.85),
    ]

    /// Side of a square that holds the whole disk of a hole with radius `r`.
    static func layerSide(_ r: CGFloat) -> CGFloat { outer * r * 2.2 }

    // MARK: Per frame

    static func drawHalf(_ context: CGContext, _ r: CGFloat, front: Bool, _ spin: CGFloat) {
        let width = outer * r * 2.2
        context.saveGState()
        context.clip(to: CGRect(x: -width / 2, y: front ? -outer * r : 0, width: width, height: outer * r))
        drawRings(context, r, squash: tilt, scale: 1, spin)
        context.restoreGState()
    }

    /// Light from the far side of the disk, bent over the top of the shadow and, thinner, under it.
    static func drawHalo(_ context: CGContext, _ r: CGFloat, _ spin: CGFloat) {
        let outline = CGMutablePath()
        for step in 0...72 {
            let angle = CGFloat(step) / 72 * .pi * 2
            let up = max(0, sin(angle))
            let radius = r * (1.06 + 0.42 * pow(up, 1.5))
            let point = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            if step == 0 { outline.move(to: point) } else { outline.addLine(to: point) }
        }
        outline.closeSubpath()

        context.saveGState()
        context.addPath(outline)
        context.clip()
        // Scale so the inner edge of the disk lands on the edge of the shadow.
        drawRings(context, r, squash: 0.92, scale: 1 / inner, -spin * 0.6)
        context.restoreGState()

        // Fade the halo toward its outer edge. Only the halo is in the layer at this point.
        let colors = [
            CGColor(gray: 0, alpha: 1),
            CGColor(gray: 0, alpha: 0.85),
            CGColor(gray: 0, alpha: 0),
        ] as CFArray
        guard let fade = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 0.3, 1]) else { return }
        context.saveGState()
        context.setBlendMode(.destinationIn)
        context.drawRadialGradient(fade, startCenter: .zero, startRadius: r, endCenter: .zero, endRadius: r * 1.5,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    /// The side that moves toward the viewer (right) looks brighter and whiter,
    /// the side that moves away looks dimmer and redder. `lift` brightens the whole disk.
    static func applyDoppler(_ context: CGContext, _ r: CGFloat, lift: CGFloat) {
        let w = outer * r * 1.1
        let start = CGPoint(x: -w, y: 0)
        let end = CGPoint(x: w, y: 0)
        let options: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

        let dim = [CGColor(gray: 0, alpha: 0.8), CGColor(gray: 0, alpha: 0.25), CGColor(gray: 0, alpha: 0)] as CFArray
        let tint = [
            CGColor(srgbRed: 0.70, green: 0.16, blue: 0.14, alpha: 0.5),
            CGColor(srgbRed: 1.00, green: 0.78, blue: 0.59, alpha: lift),
            CGColor(srgbRed: 1.00, green: 0.96, blue: 0.91, alpha: 0.25 + lift),
            CGColor(srgbRed: 1.00, green: 0.99, blue: 0.96, alpha: 0.5 + lift),
        ] as CFArray
        guard let dimGradient = CGGradient(colorsSpace: colorSpace, colors: dim, locations: [0, 0.5, 1]),
              let tintGradient = CGGradient(colorsSpace: colorSpace, colors: tint, locations: [0, 0.5, 0.75, 1]) else { return }

        context.saveGState()
        context.setBlendMode(.destinationOut)
        context.drawLinearGradient(dimGradient, start: start, end: end, options: options)
        context.setBlendMode(.sourceAtop)
        context.drawLinearGradient(tintGradient, start: start, end: end, options: options)
        context.restoreGState()
    }

    /// A hairline of light right at the edge of the shadow, brighter on the approaching side.
    static func drawPhotonRing(_ context: CGContext, _ r: CGFloat) {
        let ring = r * 1.012
        let colors = [
            CGColor(srgbRed: 0.94, green: 0.59, blue: 0.43, alpha: 0.55),
            CGColor(srgbRed: 1.00, green: 0.98, blue: 0.94, alpha: 0.95),
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) else { return }
        context.saveGState()
        context.addEllipse(in: CGRect(x: -ring, y: -ring, width: ring * 2, height: ring * 2))
        context.setLineWidth(max(0.8, r * 0.045))
        context.replacePathWithStrokedPath()
        context.clip()
        context.drawLinearGradient(gradient, start: CGPoint(x: -r, y: 0), end: CGPoint(x: r, y: 0),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    private static func drawRings(_ context: CGContext, _ r: CGFloat, squash: CGFloat, scale: CGFloat, _ spin: CGFloat) {
        for ring in rings {
            guard let image = ring.image else { continue }
            context.saveGState()
            context.scaleBy(x: 1, y: squash)
            context.rotate(by: spin * ring.speed)
            let s = r / textureScale * scale
            context.scaleBy(x: s, y: s)
            let w = CGFloat(image.width)
            context.draw(image, in: CGRect(x: -w / 2, y: -w / 2, width: w, height: w))
            context.restoreGState()
        }
    }

    // MARK: Textures, drawn once

    /// One ring of the disk, face-on: a temperature gradient with dark lanes and bright filaments.
    private static func makeTexture(from r0: CGFloat, to r1: CGFloat, seed: UInt32, streaks: Int) -> CGImage? {
        let size = Int((outer * textureScale * 2).rounded(.up)) + 4
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let center = CGPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2)
        var state = seed
        func random() -> CGFloat {
            state = state &* 1_664_525 &+ 1_013_904_223
            return CGFloat(state) / CGFloat(UInt32.max)
        }

        let ring = CGMutablePath()
        ring.addEllipse(in: CGRect(x: center.x - r1 * textureScale, y: center.y - r1 * textureScale,
                                   width: r1 * textureScale * 2, height: r1 * textureScale * 2))
        ring.addEllipse(in: CGRect(x: center.x - r0 * textureScale, y: center.y - r0 * textureScale,
                                   width: r0 * textureScale * 2, height: r0 * textureScale * 2))
        context.addPath(ring)
        context.clip(using: .evenOdd)

        // Temperature: white-hot at the inner edge, then orange, then dark red.
        let colors = [
            CGColor(srgbRed: 1.00, green: 0.98, blue: 0.94, alpha: 1),
            CGColor(srgbRed: 1.00, green: 0.90, blue: 0.71, alpha: 0.97),
            CGColor(srgbRed: 0.99, green: 0.70, blue: 0.38, alpha: 0.8),
            CGColor(srgbRed: 0.85, green: 0.44, blue: 0.19, alpha: 0.5),
            CGColor(srgbRed: 0.59, green: 0.23, blue: 0.10, alpha: 0.2),
            CGColor(srgbRed: 0.43, green: 0.15, blue: 0.08, alpha: 0),
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 0.07, 0.28, 0.55, 0.8, 1]) {
            context.drawRadialGradient(gradient, startCenter: center, startRadius: inner * textureScale,
                                       endCenter: center, endRadius: outer * textureScale, options: [])
        }

        // Turbulence: dark lanes cut into the gas, bright filaments on top.
        context.setLineCap(.round)
        for _ in 0..<streaks {
            let radius = (r0 + pow(random(), 0.8) * (r1 - r0)) * textureScale
            let start = random() * .pi * 2
            let length = 0.06 + random() * (radius < 2.2 * textureScale ? 0.9 : 0.5)
            if random() < 0.42 {
                context.setBlendMode(.destinationOut)
                context.setStrokeColor(CGColor(gray: 0, alpha: 0.12 + random() * 0.4))
            } else {
                context.setBlendMode(.sourceAtop)
                context.setStrokeColor(CGColor(srgbRed: 1, green: 0.96, blue: 0.89, alpha: 0.06 + random() * 0.34))
            }
            context.setLineWidth((0.4 + random() * 1.8) * textureScale / 48)
            context.addArc(center: center, radius: radius, startAngle: start, endAngle: start + length, clockwise: false)
            context.strokePath()
        }

        // A few hot clumps near the inner edge of the ring.
        context.setBlendMode(.sourceAtop)
        let clumpColors = [
            CGColor(srgbRed: 1, green: 0.99, blue: 0.96, alpha: 0.5),
            CGColor(srgbRed: 1, green: 0.99, blue: 0.96, alpha: 0),
        ] as CFArray
        if let clump = CGGradient(colorsSpace: colorSpace, colors: clumpColors, locations: [0, 1]) {
            for _ in 0..<(streaks / 40) {
                let radius = (r0 + random() * min(0.9, r1 - r0)) * textureScale
                let angle = random() * .pi * 2
                let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                let size = (3 + random() * 7) * textureScale / 48
                context.drawRadialGradient(clump, startCenter: point, startRadius: 0, endCenter: point, endRadius: size, options: [])
            }
        }
        return context.makeImage()
    }
}
