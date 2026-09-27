// Claude Pet — a small owl that floats on your desktop.
// Hover or click it to pick a Claude account; right-click (or ctrl-click) for the menu; drag to move.
// Build: claude-pet install-pet  (swiftc -swift-version 5 ClaudePet.swift -framework AppKit)
import AppKit
import ServiceManagement

// MARK: - Bridge to the claude-pet script

enum Species: String, CaseIterable {
    case owl, dog, cat, fox, penguin

    var label: String { rawValue.capitalized }

    /// Five body colours (hue, saturation, brightness) that suit each animal.
    var palette: [(h: CGFloat, s: CGFloat, b: CGFloat)] {
        switch self {
        case .owl: return [(0.07, 0.45, 0.62), (0.08, 0.62, 0.74), (0.6, 0.08, 0.72), (0.58, 0.4, 0.6), (0.78, 0.35, 0.6)]
        case .dog: return [(0.11, 0.5, 0.82), (0.07, 0.5, 0.55), (0.6, 0.08, 0.62), (0.45, 0.35, 0.6), (0.6, 0.15, 0.32)]
        case .cat: return [(0.08, 0.6, 0.86), (0.6, 0.1, 0.6), (0.7, 0.15, 0.3), (0.1, 0.25, 0.9), (0.72, 0.35, 0.6)]
        case .fox: return [(0.05, 0.7, 0.82), (0.07, 0.5, 0.5), (0.6, 0.1, 0.55), (0.58, 0.05, 0.88), (0.95, 0.35, 0.7)]
        case .penguin: return [(0.6, 0.2, 0.2), (0.62, 0.5, 0.32), (0.4, 0.4, 0.28), (0.75, 0.35, 0.32), (0.07, 0.4, 0.3)]
        }
    }
}

/// How an account's pet looks: an animal and one of its five colours.
/// Saved as profiles/<name>/animal ("cat 2"), so it follows renames and goes away on remove.
struct Look: Equatable {
    var species = Species.owl
    var color = 0

    static func file(_ account: String) -> String { PetController.stateDir + "/profiles/\(account)/animal" }

    static func of(_ account: String) -> Look {
        let raw = (try? String(contentsOfFile: file(account), encoding: .utf8)) ?? ""
        let parts = raw.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        var look = Look(species: parts.first.flatMap(Species.init(rawValue:)) ?? .owl, color: 0)
        if parts.count > 1, let c = Int(parts[1]), (0..<5).contains(c) {
            look.color = c
        } else {   // accounts from before colours were picked: a stable colour from the name
            var h: UInt32 = 5381
            for u in account.unicodeScalars { h = (h &* 33) &+ u.value }
            look.color = Int(h % 5)
        }
        return look
    }

    func save(for account: String) {
        try? "\(species.rawValue) \(color)\n".write(toFile: Look.file(account), atomically: true, encoding: .utf8)
    }

    var body: NSColor {
        let c = species.palette[color]
        return NSColor(calibratedHue: c.h, saturation: c.s, brightness: c.b, alpha: 1)
    }
    var wing: NSColor {
        let c = species.palette[color]
        return NSColor(calibratedHue: c.h, saturation: min(1, c.s + 0.05), brightness: c.b * 0.75, alpha: 1)
    }
    var belly: NSColor {
        if species == .penguin { return NSColor(calibratedWhite: 0.97, alpha: 1) }
        let c = species.palette[color]
        return NSColor(calibratedHue: c.h, saturation: c.s * 0.35, brightness: min(0.97, c.b * 0.4 + 0.6), alpha: 1)
    }
}

struct Account {
    let name: String
    let email: String
    let isCurrent: Bool
    let look: Look
}

enum Switcher {
    static var scriptPath: String {
        if let p = Bundle.main.path(forResource: "claude-pet", ofType: nil) { return p }
        return NSHomeDirectory() + "/.local/bin/claude-pet"
    }

    /// Runs the script off the main thread and reports (exit status, stdout, stderr) on the main thread.
    static func run(_ args: [String], completion: @escaping (Int32, String, String) -> Void) {
        let path = scriptPath
        DispatchQueue.global(qos: .userInitiated).async {
            let result = execute(path, args)
            DispatchQueue.main.async { completion(result.0, result.1, result.2) }
        }
    }

    private final class DataBox { var data = Data() }

    private static func execute(_ path: String, _ args: [String]) -> (Int32, String, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [path] + args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            return (127, "", "Couldn't run \(path): \(error.localizedDescription)")
        }
        // drain stderr on another thread so a full pipe can't deadlock us
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        let errHandle = errPipe.fileHandleForReading
        DispatchQueue.global().async {
            errBox.data = errHandle.readDataToEndOfFile()
            group.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        proc.waitUntilExit()
        return (proc.terminationStatus,
                String(decoding: outData, as: UTF8.self),
                String(decoding: errBox.data, as: UTF8.self))
    }
}

// MARK: - The owl

final class OwlView: NSView {
    var name = "" { didSet { needsDisplay = true } }
    var busy = false { didSet { needsDisplay = true } }
    var eyesClosed = false { didSet { needsDisplay = true } }
    var phase: CGFloat = 0 { didSet { if busy { needsDisplay = true } } }
    var look = Look() { didSet { needsDisplay = true } }
    var species: Species { look.species }
    var checked = false { didSet { needsDisplay = true } }   // "✓" in the name tag
    var testMode = false { didSet { needsDisplay = true } }  // " · test" in the name tag
    var petScale: CGFloat = 1 { didSet { needsDisplay = true } }   // 1 = the 124-wide design size

    /// The pet is drawn on a 124×146 design grid, scaled by petScale, standing on a name-tag strip
    /// that never shrinks below the standard 11pt text, so names stay readable at every size.
    static let tagHeight: CGFloat = 22
    var tagHeight: CGFloat { showsTag ? OwlView.tagHeight * max(1, petScale) : 0 }

    /// Where the design grid lands in the view: offset, then scale.
    var petOrigin: (x: CGFloat, y: CGFloat) {
        ((bounds.width - 124 * petScale) / 2, bottomMargin + tagHeight - 26 * petScale)
    }
    var bottomMargin: CGFloat = 0   // room under the feet for the outline's shadow (main pet)

    /// Room for a pet at this scale with its tag; at least minWidth wide so the name fits.
    static func frameSize(petScale k: CGFloat, minWidth: CGFloat, withTag: Bool = true) -> NSSize {
        NSSize(width: max(round(124 * k), minWidth), height: round((withTag ? tagHeight * max(1, k) : 0) + 120 * k))
    }
    var draggable = true

    var onClick: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    var onDrag: (() -> Void)?
    var clampOrigin: ((NSPoint) -> NSPoint)?   // keeps a dragged pet on screen
    var onMoved: ((NSPoint) -> Void)?
    var onHover: ((Bool) -> Void)?
    var onEyeClick: ((Int) -> Void)?   // 0 = left eye, 1 = right eye

    /// Which eye (if any) is under a point in view coordinates. Matches the eye positions in draw().
    func eye(at pt: NSPoint) -> Int? {
        let o = petOrigin
        let x = (pt.x - o.x) / petScale, y = (pt.y - o.y) / petScale   // back to the design grid
        for (i, cx) in [CGFloat(45), 79].enumerated() where hypot(x - cx, y - 96) <= 17 {
            return i
        }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    private var dragStartMouse = NSPoint.zero
    private var dragStartOrigin = NSPoint.zero
    private var didDrag = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var showsTag = true { didSet { needsDisplay = true } }   // off for the main pet and thumbnails
    var outlined = false   // light edge + soft shadow, so the pet shows on any wallpaper

    // MARK: animations (bounce when a profile is picked, flap/wag when a switch succeeds)

    private var bounceStart: CFTimeInterval = 0
    private var cheerStart: CFTimeInterval = 0
    private var animTimer: Timer?

    private func progress(_ start: CFTimeInterval, _ duration: Double) -> CGFloat? {
        guard start > 0 else { return nil }
        let p = (CACurrentMediaTime() - start) / duration
        return p < 1 ? CGFloat(p) : nil
    }
    var bounceProgress: CGFloat? { progress(bounceStart, 0.45) }
    var cheerProgress: CGFloat? { progress(cheerStart, 1.1) }

    /// A quick hop with a little squash, as if the pet heard you.
    func bounce() { bounceStart = CACurrentMediaTime(); animate() }
    /// Wings flap (owl, penguin) or the tail wags (dog, cat, fox): the switch worked.
    func cheer() { cheerStart = CACurrentMediaTime(); animate() }

    private func animate() {
        guard animTimer == nil else { return }
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            self.needsDisplay = true
            if self.bounceProgress == nil && self.cheerProgress == nil {
                timer.invalidate()
                self.animTimer = nil
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = look.body, wing = look.wing, belly = look.belly
        let dark = NSColor(calibratedWhite: 0.12, alpha: 1)
        let orange = NSColor(calibratedRed: 0.98, green: 0.62, blue: 0.2, alpha: 1)
        let pink = NSColor(calibratedRed: 0.96, green: 0.55, blue: 0.62, alpha: 1)

        // everything is laid out on a 100-wide grid; the eyes sit in the same place for every animal
        let ox: CGFloat = 12, oy: CGFloat = 30
        NSGraphicsContext.saveGraphicsState()
        let grid = NSAffineTransform()
        grid.translateX(by: petOrigin.x, yBy: petOrigin.y)
        grid.scale(by: petScale)
        grid.concat()
        if let b = bounceProgress {   // hop up and stretch a little, pivoting on the feet
            let hop = sin(.pi * b)
            let t = NSAffineTransform()
            t.translateX(by: 62, yBy: 30 + 10 * hop)
            t.scaleX(by: 1 - 0.05 * hop, yBy: 1 + 0.07 * hop)
            t.translateX(by: -62, yBy: -30)
            t.concat()
        }
        // outline: the whole pet is drawn into two transparency layers, so the soft dark shadow and
        // the thin light edge go around its outline once, not around every part
        let cg = outlined ? NSGraphicsContext.current?.cgContext : nil
        if let cg = cg {
            cg.setShadow(offset: CGSize(width: 0, height: -1), blur: 4,
                         color: NSColor(calibratedWhite: 0, alpha: 0.4).cgColor)
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            cg.setShadow(offset: .zero, blur: 1.6, color: NSColor(calibratedWhite: 1, alpha: 1).cgColor)
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        let flapDeg: CGFloat = cheerProgress.map { 38 * abs(sin(3 * .pi * $0)) } ?? 0
        let wagDeg: CGFloat = cheerProgress.map { 20 * sin(6 * .pi * $0) } ?? 0
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: ox + x, y: oy + y, width: w, height: h)
        }
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x, y: oy + y) }
        func poly(_ pts: [(CGFloat, CGFloat)]) -> NSBezierPath {
            let path = NSBezierPath()
            for (i, q) in pts.enumerated() {
                if i == 0 { path.move(to: p(q.0, q.1)) } else { path.line(to: p(q.0, q.1)) }
            }
            path.close()
            return path
        }
        func line(_ width: CGFloat, _ build: (NSBezierPath) -> Void) {
            let path = NSBezierPath()
            path.lineWidth = width
            path.lineCapStyle = .round
            build(path)
            path.stroke()
        }
        /// Draw something rotated by `deg` around a point on the grid (wings, tails).
        func pivoted(_ px: CGFloat, _ py: CGFloat, _ deg: CGFloat, _ draw: () -> Void) {
            guard deg != 0 else { draw(); return }
            NSGraphicsContext.saveGraphicsState()
            let t = NSAffineTransform()
            t.translateX(by: ox + px, yBy: oy + py)
            t.rotate(byDegrees: deg)
            t.translateX(by: -(ox + px), yBy: -(oy + py))
            t.concat()
            draw()
            NSGraphicsContext.restoreGraphicsState()
        }

        // soft shadow
        NSColor(calibratedWhite: 0, alpha: 0.18).setFill()
        NSBezierPath(ovalIn: r(22, -4, 56, 8)).fill()

        // tails, behind the body
        switch species {
        case .cat:
            body.setStroke()
            pivoted(80, 12, wagDeg) {
                line(9) { $0.move(to: p(80, 12)); $0.curve(to: p(102, 58), controlPoint1: p(106, 14), controlPoint2: p(96, 40)) }
            }
        case .dog:
            wing.setStroke()
            pivoted(82, 20, wagDeg * 1.4) {
                line(8) { $0.move(to: p(82, 20)); $0.curve(to: p(100, 46), controlPoint1: p(96, 18), controlPoint2: p(100, 32)) }
            }
        case .fox:
            var t = AffineTransform(translationByX: ox + 92, byY: oy + 22)
            t.rotate(byDegrees: -62)
            let tail = NSBezierPath(ovalIn: NSRect(x: -10, y: -24, width: 20, height: 48))
            let tip = NSBezierPath(ovalIn: NSRect(x: -7, y: 10, width: 14, height: 14))
            tail.transform(using: t)
            tip.transform(using: t)
            pivoted(84, 16, wagDeg) {
                body.setFill(); tail.fill()
                belly.setFill(); tip.fill()
            }
        default: break
        }

        // feet
        (species == .owl || species == .penguin ? orange : wing).setFill()
        NSBezierPath(ovalIn: r(30, 0, 16, 8)).fill()
        NSBezierPath(ovalIn: r(54, 0, 16, 8)).fill()

        // ears, then the body
        body.setFill()
        switch species {
        case .owl:
            poly([(16, 78), (10, 108), (38, 90)]).fill()
            poly([(84, 78), (90, 108), (62, 90)]).fill()
        case .cat:
            poly([(12, 74), (14, 110), (42, 92)]).fill()
            poly([(88, 74), (86, 110), (58, 92)]).fill()
        case .fox:
            poly([(12, 72), (16, 114), (44, 90)]).fill()
            poly([(88, 72), (84, 114), (56, 90)]).fill()
        default: break
        }
        NSBezierPath(ovalIn: r(8, 4, 84, 92)).fill()

        // inner ears, sides, front
        switch species {
        case .owl:
            wing.setFill()
            pivoted(12, 54, -flapDeg) { NSBezierPath(ovalIn: r(3, 16, 18, 42)).fill() }
            pivoted(88, 54, flapDeg) { NSBezierPath(ovalIn: r(79, 16, 18, 42)).fill() }
            belly.setFill()
            NSBezierPath(ovalIn: r(26, 8, 48, 50)).fill()
            wing.setStroke()
            for i in 0..<3 {   // little chevron feathers
                let y = CGFloat(18 + i * 10)
                line(1.6) {
                    $0.move(to: p(41, y + 3)); $0.line(to: p(45, y)); $0.line(to: p(49, y + 3))
                    $0.move(to: p(51, y + 3)); $0.line(to: p(55, y)); $0.line(to: p(59, y + 3))
                }
            }
        case .cat:
            pink.setFill()
            poly([(18, 84), (19, 103), (35, 92)]).fill()
            poly([(82, 84), (81, 103), (65, 92)]).fill()
            belly.setFill()
            NSBezierPath(ovalIn: r(28, 8, 44, 34)).fill()
        case .dog:
            belly.setFill()
            NSBezierPath(ovalIn: r(30, 6, 40, 26)).fill()
            wing.setFill()   // floppy ears
            let ears = NSBezierPath()
            ears.move(to: p(20, 94))
            ears.curve(to: p(4, 50), controlPoint1: p(4, 94), controlPoint2: p(-2, 66))
            ears.curve(to: p(22, 60), controlPoint1: p(10, 40), controlPoint2: p(22, 48))
            ears.close()
            ears.move(to: p(80, 94))
            ears.curve(to: p(96, 50), controlPoint1: p(96, 94), controlPoint2: p(102, 66))
            ears.curve(to: p(78, 60), controlPoint1: p(90, 40), controlPoint2: p(78, 48))
            ears.close()
            ears.fill()
        case .fox:
            belly.setFill()
            poly([(20, 84), (22, 104), (38, 91)]).fill()
            poly([(80, 84), (78, 104), (62, 91)]).fill()
            NSBezierPath(ovalIn: r(32, 6, 36, 24)).fill()
            let cheeks = NSBezierPath()   // white muzzle
            cheeks.move(to: p(10, 60))
            cheeks.curve(to: p(50, 30), controlPoint1: p(18, 40), controlPoint2: p(38, 30))
            cheeks.curve(to: p(90, 60), controlPoint1: p(62, 30), controlPoint2: p(82, 40))
            cheeks.curve(to: p(10, 60), controlPoint1: p(70, 50), controlPoint2: p(30, 50))
            cheeks.fill()
        case .penguin:
            wing.setFill()   // flippers
            pivoted(8, 56, -flapDeg) { NSBezierPath(ovalIn: r(0, 16, 16, 44)).fill() }
            pivoted(92, 56, flapDeg) { NSBezierPath(ovalIn: r(84, 16, 16, 44)).fill() }
            belly.setFill()
            NSBezierPath(ovalIn: r(16, 6, 68, 78)).fill()
        }

        // eyes
        let eyeR: CGFloat = 15
        let rim = species == .owl ? orange : wing
        for c in [p(33, 66), p(67, 66)] {
            rim.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - eyeR - 2, y: c.y - eyeR - 2, width: (eyeR + 2) * 2, height: (eyeR + 2) * 2)).fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - eyeR, y: c.y - eyeR, width: eyeR * 2, height: eyeR * 2)).fill()
            if eyesClosed {
                dark.setStroke()
                line(3) {
                    $0.move(to: NSPoint(x: c.x - 9, y: c.y))
                    $0.curve(to: NSPoint(x: c.x + 9, y: c.y),
                             controlPoint1: NSPoint(x: c.x - 4, y: c.y - 6),
                             controlPoint2: NSPoint(x: c.x + 4, y: c.y - 6))
                }
            } else {
                let dx: CGFloat = busy ? cos(phase) * 6 : 0
                let dy: CGFloat = busy ? sin(phase) * 6 : 0
                dark.setFill()
                NSBezierPath(ovalIn: NSRect(x: c.x - 7 + dx, y: c.y - 7 + dy, width: 14, height: 14)).fill()
                NSColor.white.setFill()
                NSBezierPath(ovalIn: NSRect(x: c.x - 3 + dx, y: c.y + 1 + dy, width: 4, height: 4)).fill()
            }
        }

        // beak, nose, mouth
        switch species {
        case .owl, .penguin:
            orange.setFill()
            poly([(44, 52), (56, 52), (50, 40)]).fill()
        case .cat:
            pink.setFill()
            poly([(45, 50), (55, 50), (50, 44)]).fill()
            dark.setStroke()
            line(1.6) {
                $0.move(to: p(50, 44)); $0.line(to: p(50, 41))
                $0.move(to: p(44, 39)); $0.curve(to: p(50, 41), controlPoint1: p(46, 37), controlPoint2: p(49, 38))
                $0.move(to: p(56, 39)); $0.curve(to: p(50, 41), controlPoint1: p(54, 37), controlPoint2: p(51, 38))
            }
            NSColor(calibratedWhite: 0.12, alpha: 0.55).setStroke()
            line(1.2) {   // whiskers
                $0.move(to: p(30, 47)); $0.line(to: p(4, 51))
                $0.move(to: p(30, 43)); $0.line(to: p(4, 42))
                $0.move(to: p(70, 47)); $0.line(to: p(96, 51))
                $0.move(to: p(70, 43)); $0.line(to: p(96, 42))
            }
        case .dog:
            belly.setFill()
            NSBezierPath(ovalIn: r(34, 32, 32, 22)).fill()
            pink.setFill()
            NSBezierPath(ovalIn: r(46, 30, 8, 8)).fill()
            dark.setFill()
            NSBezierPath(ovalIn: r(44, 46, 12, 8)).fill()
            dark.setStroke()
            line(1.6) {
                $0.move(to: p(50, 46)); $0.line(to: p(50, 39))
                $0.move(to: p(43, 38)); $0.curve(to: p(50, 39), controlPoint1: p(45, 36), controlPoint2: p(48, 37))
                $0.move(to: p(57, 38)); $0.curve(to: p(50, 39), controlPoint1: p(55, 36), controlPoint2: p(52, 37))
            }
        case .fox:
            dark.setFill()
            NSBezierPath(ovalIn: r(45, 38, 10, 7)).fill()
        }

        if let cg = cg {
            cg.endTransparencyLayer()   // applies the light edge
            cg.endTransparencyLayer()   // then the soft shadow
        }
        NSGraphicsContext.restoreGraphicsState()

        // name tag, in view points (not scaled with the pet)
        guard showsTag else { return }
        let t = max(1, petScale)
        let text = name.isEmpty ? "click to set up" : (checked ? "✓ " + name : name) + (testMode ? " · test" : "")
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11 * t, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: para,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let pillH = tagHeight - 2
        let pillW = min(bounds.width - 1, size.width + 9 * t)
        let pill = NSRect(x: (bounds.width - pillW) / 2, y: 1, width: pillW, height: pillH)
        NSColor(calibratedWhite: 0, alpha: 0.68).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pillH / 2, yRadius: pillH / 2).fill()
        (text as NSString).draw(in: pill.insetBy(dx: 4.5 * t, dy: (pillH - size.height) / 2), withAttributes: attrs)
    }

    // click vs drag
    override func mouseDown(with event: NSEvent) {
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin ?? .zero
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        let m = NSEvent.mouseLocation
        let dx = m.x - dragStartMouse.x
        let dy = m.y - dragStartMouse.y
        if abs(dx) + abs(dy) > 3 && draggable { didDrag = true }
        if didDrag {
            let target = NSPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy)
            window?.setFrameOrigin(clampOrigin?(target) ?? target)
            onDrag?()
        }
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag {
            if let o = window?.frame.origin { onMoved?(o) }
        } else if event.modifierFlags.contains(.control) {
            onMenu?(event)
        } else {
            if let e = eye(at: convert(event.locationInWindow, from: nil)) { onEyeClick?(e) }
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) { onMenu?(event) }
}

// MARK: - The speech bubble

/// A small note next to the owl: progress, results, errors. First line is the title. Click to dismiss.
final class BubbleView: NSView {
    var text = "" { didSet { needsDisplay = true } }
    var isError = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    static let maxTextWidth: CGFloat = 250
    static let pad = NSSize(width: 12, height: 9)

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func attributed() -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2
        let s = NSMutableAttributedString()
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            s.append(NSAttributedString(string: (i > 0 ? "\n" : "") + line, attributes: [
                .font: i == 0 ? NSFont.systemFont(ofSize: 12, weight: .semibold) : NSFont.systemFont(ofSize: 11.5),
                .foregroundColor: i == 0 ? NSColor.white : NSColor(calibratedWhite: 0.86, alpha: 1),
                .paragraphStyle: para,
            ]))
        }
        return s
    }

    func fittingSize() -> NSSize {
        let r = attributed().boundingRect(with: NSSize(width: BubbleView.maxTextWidth, height: 1000),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        return NSSize(width: ceil(r.width) + 2 + BubbleView.pad.width * 2, height: ceil(r.height) + BubbleView.pad.height * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        (isError ? NSColor(calibratedRed: 0.45, green: 0.1, blue: 0.08, alpha: 0.94)
                 : NSColor(calibratedWhite: 0.1, alpha: 0.9)).setFill()
        box.fill()
        NSColor(calibratedWhite: 1, alpha: 0.18).setStroke()
        box.lineWidth = 1
        box.stroke()
        attributed().draw(in: bounds.insetBy(dx: BubbleView.pad.width, dy: BubbleView.pad.height))
    }

    override func mouseUp(with event: NSEvent) { onClick?() }
}

// MARK: - The account picker

/// A round button beside the small owls, showing an SF Symbol: "+" adds an account, the gear opens the menu.
final class RoundButton: NSView {
    let symbol: String
    var pointSize: CGFloat = 14
    var badge = false { didSet { needsDisplay = true } }   // small red dot, e.g. an update is waiting
    var hoverColor: NSColor?   // fill while hovered (e.g. red for delete); default a lighter grey
    var onClick: ((RoundButton) -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }

    init(symbol: String, tip: String, frame: NSRect) {
        self.symbol = symbol
        super.init(frame: frame)
        toolTip = tip
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    var onHover: ((Bool) -> Void)?   // for our own hover label (tooltips don't show for a background app)
    override func mouseEntered(with event: NSEvent) { hovering = true; onHover?(true) }
    override func mouseExited(with event: NSEvent) { hovering = false; onHover?(false) }
    override func mouseUp(with event: NSEvent) { onClick?(self) }

    override func draw(_ dirtyRect: NSRect) {
        let fill = hovering ? hoverColor ?? NSColor(calibratedWhite: 0.25, alpha: 0.9) : NSColor(calibratedWhite: 0.1, alpha: 0.9)
        if symbol == "xmark" {
            // the small delete ×: a plain disc with a pixel-exact cross. On 1x screens it's drawn
            // without smoothing (a smoothed tiny diagonal turns to grey fuzz); Retina stays smooth.
            fill.setFill()
            NSBezierPath(ovalIn: bounds).fill()
            NSColor.white.set()
            if (window?.backingScaleFactor ?? 2) < 2 {
                // 1x: a 7-pixel cross laid down pixel by pixel, two pixels wide
                let n = 7, start = CGFloat((Int(bounds.width) - n - 1) / 2)
                for i in 0..<n {
                    let a = start + CGFloat(i), b = start + CGFloat(n - 1 - i)
                    NSRect(x: a, y: a, width: 2, height: 1).fill()
                    NSRect(x: b, y: a, width: 2, height: 1).fill()
                }
            } else {
                let lo = bounds.width * 0.33, hi = bounds.width - lo
                let x = NSBezierPath()
                x.lineWidth = 1.6
                x.lineCapStyle = .round
                x.move(to: NSPoint(x: lo, y: lo)); x.line(to: NSPoint(x: hi, y: hi))
                x.move(to: NSPoint(x: lo, y: hi)); x.line(to: NSPoint(x: hi, y: lo))
                x.stroke()
            }
            return
        }
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        fill.setFill()
        circle.fill()
        NSColor(calibratedWhite: 1, alpha: 0.3).setStroke()
        circle.stroke()
        // Of the requested size and one point either side, use the one whose painted width has the same
        // odd/even parity as the circle, so the icon can sit exactly in the middle on whole pixels.
        var picked: (img: NSImage, ink: NSRect)?
        for ps in [pointSize, pointSize + 1, pointSize - 1] {
            let config = NSImage.SymbolConfiguration(pointSize: ps, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?
                .withSymbolConfiguration(config) else { continue }
            let ink = RoundButton.inkRect(of: img, key: "\(symbol)@\(ps)")
            if picked == nil { picked = (img, ink) }
            if Int((bounds.width - ink.width).rounded()) % 2 == 0 && Int((bounds.height - ink.height).rounded()) % 2 == 0 {
                picked = (img, ink)
                break
            }
        }
        guard let (img, ink) = picked else { return }
        // centre what the symbol actually paints (measured once), not its padded image box
        let s = img.size
        let rect = backingAlignedRect(NSRect(x: bounds.midX - ink.midX, y: bounds.midY - ink.midY,
                                             width: s.width, height: s.height), options: .alignAllEdgesNearest)
        img.draw(in: rect)   // snapped to whole pixels so it stays sharp
        if badge {
            let d = round(bounds.width * 0.32)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.maxX - d, y: bounds.maxY - d, width: d, height: d)).fill()
        }
    }

    private static var inkCache: [String: NSRect] = [:]

    /// The part of an image that isn't transparent, in the image's own points.
    static func inkRect(of img: NSImage, key: String) -> NSRect {
        if let r = inkCache[key] { return r }
        let k: CGFloat = 8   // measure at 8x for sub-point precision
        let w = Int(ceil(img.size.width * k)), h = Int(ceil(img.size.height * k))
        var r = NSRect(origin: .zero, size: img.size)
        if w > 0, h > 0, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            img.draw(in: NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
            NSGraphicsContext.restoreGraphicsState()
            var minX = w, minY = h, maxX = -1, maxY = -1
            for y in 0..<h {
                for x in 0..<w where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            if maxX >= minX {
                // bitmap rows run top-down; the image's points run bottom-up
                r = NSRect(x: CGFloat(minX) / k, y: CGFloat(h - 1 - maxY) / k,
                           width: CGFloat(maxX - minX + 1) / k, height: CGFloat(maxY - minY + 1) / k)
            }
        }
        inkCache[key] = r
        return r
    }
}

// MARK: - Manage accounts window

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

extension OwlView {
    /// A pet without its name tag, cropped to the animal, `size` points wide.
    static func thumbnail(_ look: Look, size: CGFloat) -> OwlView {
        let k = size / 124
        let v = OwlView(frame: NSRect(x: 0, y: 0, width: size, height: round(120 * k)))
        v.showsTag = false
        v.petScale = k
        v.look = look
        v.draggable = false
        return v
    }
}

extension Look {
    /// The pet as a small image, for menu items.
    func image(width: CGFloat) -> NSImage? {
        let v = OwlView.thumbnail(self, size: width)
        // drawn on demand at the screen's resolution, so it stays crisp on Retina
        return NSImage(size: v.frame.size, flipped: false) { _ in
            v.draw(v.bounds)
            return true
        }
    }
}

/// A solid, coloured button (red Delete, blue Save) that looks the same whether or not the window
/// is focused, unlike a standard push button.
final class PillButton: NSView {
    var title: String { didSet { needsDisplay = true } }
    let color: NSColor
    var onClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    init(title: String, color: NSColor, frame: NSRect) {
        self.title = title
        self.color = color
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill = pressed ? color.blended(withFraction: 0.25, of: .black) ?? color
            : hovering ? color.blended(withFraction: 0.12, of: .black) ?? color : color
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                                 withAttributes: attrs)
    }
}

/// A clickable card (account row, animal tile) or colour circle (swatch) that can show a selection.
final class PickTile: FlippedView {
    var selected = false { didSet { needsDisplay = true } }
    var swatch: NSColor? { didSet { needsDisplay = true } }   // set = draw a colour circle
    var onClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }   // children don't take clicks
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        if let c = swatch {
            c.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 5, dy: 5)).fill()
            if selected || hovering {
                (selected ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
                let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
                ring.lineWidth = 2.5
                ring.stroke()
            }
            return
        }
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        if selected {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            card.fill()
            NSColor.controlAccentColor.setStroke()
            card.lineWidth = 2
            card.stroke()
        } else if hovering {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            card.fill()
        }
    }
}

/// Lets a closure be a control's target/action (checkboxes and the slider in Settings).
final class ActionHandler: NSObject {
    let fn: (Any?) -> Void
    init(_ fn: @escaping (Any?) -> Void) { self.fn = fn }
    @objc func fire(_ sender: Any?) { fn(sender) }
}

/// Claude Pet's settings: sections on the left, the chosen section's page on the right. The
/// Profiles page shows every profile as a card (✓ = the one in use) with an editor for the
/// selected one underneath.
final class SettingsWindow: NSObject {
    enum Section: Int, CaseIterable {
        case profiles, pet, switching, about
        var title: String { ["Profiles", "Pet", "Switching", "About"][rawValue] }
        var symbol: String { ["person.2.fill", "pawprint.fill", "arrow.left.arrow.right", "info.circle.fill"][rawValue] }
    }

    static let sidebarW: CGFloat = 180, paneW: CGFloat = 520, minHeight: CGFloat = 580

    weak var controller: PetController?
    let window: NSWindow
    let content = FlippedView(frame: NSRect(x: 0, y: 0, width: sidebarW + paneW, height: minHeight))
    let sidebar = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: sidebarW, height: minHeight))
    let pane = FlippedView(frame: NSRect(x: sidebarW, y: 0, width: paneW, height: minHeight))
    var sectionRows: [PickTile] = []
    let aboutBadge = NSView(frame: NSRect(x: SettingsWindow.sidebarW - 20 - 22, y: 13, width: 8, height: 8))   // update waiting
    var section = Section.profiles
    var handlers: [ActionHandler] = []   // keep control targets alive (targets are weak)

    // Profiles page
    var editing: String?          // the profile being edited; nil while adding a new one
    var pendingSelect: String?    // show this profile once the list reloads (after a rename)
    var look = Look()
    var nameField: NSTextField?
    var noteLabel: NSTextField?
    var preview: OwlView?
    var petTiles: [(tile: PickTile, thumb: OwlView)] = []
    var swatches: [PickTile] = []

    var accounts: [Account] { controller?.accounts ?? [] }

    init(controller: PetController) {
        self.controller = controller
        window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Claude Pet Settings"
        window.isReleasedWhenClosed = false
        window.contentView = content
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        content.addSubview(sidebar)
        content.addSubview(pane)
        for s in Section.allCases {
            let row = PickTile(frame: NSRect(x: 10, y: 16 + CGFloat(s.rawValue) * 40, width: SettingsWindow.sidebarW - 20, height: 34))
            let icon = NSImageView(frame: NSRect(x: 10, y: 8, width: 20, height: 18))
            icon.image = NSImage(systemSymbolName: s.symbol, accessibilityDescription: nil)
            icon.contentTintColor = .controlAccentColor
            row.addSubview(icon)
            row.addSubview(label(s.title, x: 40, y: 8, size: 13, weight: .medium))
            row.onClick = { [weak self] in self?.show(s) }
            if s == .about {
                aboutBadge.wantsLayer = true
                aboutBadge.layer?.backgroundColor = NSColor.systemRed.cgColor
                aboutBadge.layer?.cornerRadius = 4
                aboutBadge.isHidden = true
                row.addSubview(aboutBadge)
            }
            content.addSubview(row)
            sectionRows.append(row)
        }
        window.center()
    }

    // MARK: helpers

    func label(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight,
               secondary: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        if secondary { l.textColor = .secondaryLabelColor }
        l.sizeToFit()
        l.setFrameOrigin(NSPoint(x: x, y: y))
        return l
    }

    func note(_ text: String, y: CGFloat, height: CGFloat = 32) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.frame = NSRect(x: 24, y: y, width: SettingsWindow.paneW - 48, height: height)
        return l
    }

    func header(_ title: String, _ subtitle: String) {
        pane.addSubview(label(title, x: 24, y: 20, size: 20, weight: .bold))
        pane.addSubview(label(subtitle, x: 24, y: 50, size: 12, weight: .regular, secondary: true))
    }

    func checkbox(_ title: String, y: CGFloat, on: Bool, _ changed: @escaping (Bool) -> Void) {
        let h = ActionHandler { sender in changed((sender as? NSButton)?.state == .on) }
        handlers.append(h)
        let b = NSButton(checkboxWithTitle: title, target: h, action: #selector(ActionHandler.fire(_:)))
        b.state = on ? .on : .off
        b.sizeToFit()
        b.setFrameOrigin(NSPoint(x: 24, y: y))
        pane.addSubview(b)
    }

    func separator(y: CGFloat) {
        let line = NSBox(frame: NSRect(x: 24, y: y, width: SettingsWindow.paneW - 48, height: 1))
        line.boxType = .separator
        pane.addSubview(line)
    }

    /// Grow the window for a taller page (e.g. many profiles), keeping its top edge in place.
    func fit(height: CGFloat) {
        let h = max(SettingsWindow.minHeight, height)
        guard abs(content.frame.height - h) > 0.5 else { return }
        var f = window.frame
        let delta = h - content.frame.height
        f.size.height += delta
        f.origin.y -= delta
        window.setFrame(f, display: true)
        sidebar.frame.size.height = h
        pane.frame.size.height = h
    }

    // MARK: showing

    /// Open on a section; `adding` opens Profiles on a new profile.
    func show(_ s: Section? = nil, adding: Bool = false) {
        if let s = s { section = s }
        if section == .profiles {
            if adding || accounts.isEmpty {
                editing = nil
                look = Look(species: .owl, color: freeColor(for: .owl))
            } else if editing == nil || !accounts.contains(where: { $0.name == editing }) {
                selectProfile(accounts.first { $0.isCurrent }?.name ?? accounts.first?.name, render: false)
            }
        }
        render()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if section == .profiles && editing == nil { window.makeFirstResponder(nameField) }
    }

    func render() {
        pane.subviews.forEach { $0.removeFromSuperview() }
        handlers = []
        nameField = nil; noteLabel = nil; preview = nil
        petTiles = []; swatches = []
        for (i, row) in sectionRows.enumerated() { row.selected = i == section.rawValue }
        aboutBadge.isHidden = controller?.update == nil
        switch section {
        case .profiles: buildProfiles()
        case .pet: buildPet()
        case .switching: buildSwitching()
        case .about: buildAbout()
        }
    }

    /// Called after every refresh of the profile list.
    func accountsChanged() {
        guard window.isVisible else { return }
        if let w = pendingSelect, accounts.contains(where: { $0.name == w }) { editing = w }
        pendingSelect = nil
        if let e = editing, !accounts.contains(where: { $0.name == e }) {
            selectProfile(accounts.first { $0.isCurrent }?.name, render: false)
        } else if let e = editing, let a = accounts.first(where: { $0.name == e }) {
            look = a.look
        }
        render()
    }

    // MARK: Profiles

    func selectProfile(_ name: String?, render again: Bool = true) {
        if let n = name, let a = accounts.first(where: { $0.name == n }) {
            editing = n
            look = a.look
        } else {
            editing = nil
            look = Look(species: .owl, color: freeColor(for: .owl))
        }
        if again { render() }
        if editing == nil { window.makeFirstResponder(nameField) }
    }

    /// The first colour of this animal no other profile uses yet, so two owls don't look alike.
    func freeColor(for s: Species) -> Int {
        let used = Set(accounts.filter { $0.look.species == s && $0.name != editing }.map { $0.look.color })
        return (0..<5).first { !used.contains($0) } ?? 0
    }

    func buildProfiles() {
        let first = accounts.isEmpty
        header("Profiles", first ? "Save the Claude account you're logged into now as your first profile."
                                 : "Click a profile to edit it. ✓ marks the one in use.")
        // cards: one per profile, then Add
        let cardW: CGFloat = 88, cardH: CGFloat = 96, gap: CGFloat = 8, perRow = 5
        func cardFrame(_ i: Int) -> NSRect {
            NSRect(x: 24 + CGFloat(i % perRow) * (cardW + gap), y: 80 + CGFloat(i / perRow) * (cardH + gap),
                   width: cardW, height: cardH)
        }
        for (i, a) in accounts.enumerated() {
            let card = PickTile(frame: cardFrame(i))
            let thumb = OwlView.thumbnail(a.look, size: 48)
            thumb.setFrameOrigin(NSPoint(x: (cardW - 48) / 2, y: 10))
            card.addSubview(thumb)
            // the name, with a green ✓ in front of it on the profile in use
            let name = label(a.name, x: 0, y: 66, size: 12, weight: .semibold)
            name.lineBreakMode = .byTruncatingTail
            let tickW: CGFloat = a.isCurrent ? 16 : 0
            name.frame.size.width = min(name.frame.width, cardW - 8 - tickW)
            let startX = (cardW - tickW - name.frame.width) / 2
            if a.isCurrent {
                let tick = NSImageView(frame: NSRect(x: startX, y: 66, width: 13, height: 14))
                tick.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "In use")
                tick.contentTintColor = .systemGreen
                tick.imageScaling = .scaleProportionallyUpOrDown
                card.addSubview(tick)
            }
            name.setFrameOrigin(NSPoint(x: startX + tickW, y: 66))
            card.addSubview(name)
            card.toolTip = a.email.isEmpty ? nil : a.email
            card.selected = a.name == editing
            let n = a.name
            card.onClick = { [weak self] in self?.selectProfile(n) }
            pane.addSubview(card)
            // × in the top-right corner deletes the profile (after asking)
            let close = RoundButton(symbol: "xmark", tip: "Delete \(a.name)",
                                    frame: NSRect(x: card.frame.maxX - 22, y: card.frame.minY + 4, width: 18, height: 18))
            close.pointSize = 8
            close.hoverColor = .systemRed
            close.onClick = { [weak self] _ in self?.deleteClicked(n) }
            pane.addSubview(close)
        }
        let add = PickTile(frame: cardFrame(accounts.count))
        let plus = NSImageView(frame: NSRect(x: (cardW - 34) / 2, y: 18, width: 34, height: 34))
        plus.image = NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: "Add")
        plus.contentTintColor = .controlAccentColor
        plus.imageScaling = .scaleProportionallyUpOrDown
        add.addSubview(plus)
        let addLabel = label(first ? "First profile" : "Add", x: 4, y: 66, size: 12, weight: .medium)
        addLabel.frame = NSRect(x: 4, y: 66, width: cardW - 8, height: 16)
        addLabel.alignment = .center
        add.addSubview(addLabel)
        add.selected = editing == nil
        add.onClick = { [weak self] in self?.selectProfile(nil) }
        pane.addSubview(add)

        // editor for the selected card
        let rows = (accounts.count + 1 + perRow - 1) / perRow
        let y0 = 80 + CGFloat(rows) * (cardH + gap) + 4
        separator(y: y0)
        let current = accounts.first { $0.name == editing }

        let pv = OwlView.thumbnail(look, size: 100)
        pv.setFrameOrigin(NSPoint(x: 24, y: y0 + 16))
        pane.addSubview(pv)
        preview = pv
        let title = label(editing ?? (first ? "Your first profile" : "New profile"), x: 140, y: y0 + 16, size: 16, weight: .bold)
        title.frame.size.width = SettingsWindow.paneW - 164
        title.lineBreakMode = .byTruncatingTail
        pane.addSubview(title)
        let sub = current.map { [$0.isCurrent ? "In use" : nil, $0.email.isEmpty ? nil : $0.email].compactMap { $0 }.joined(separator: " · ") }
            ?? (first ? "The Claude account you're logged into now" : "You'll log in to it after adding")
        let subLabel = label(sub, x: 140, y: y0 + 40, size: 12, weight: .regular, secondary: true)
        subLabel.frame.size.width = SettingsWindow.paneW - 164
        subLabel.lineBreakMode = .byTruncatingTail
        pane.addSubview(subLabel)
        pane.addSubview(label("Name", x: 140, y: y0 + 66, size: 12, weight: .medium))
        let field = NSTextField(frame: NSRect(x: 140, y: y0 + 84, width: 220, height: 24))
        field.stringValue = editing ?? ""
        field.placeholderString = editing == nil ? (first ? "e.g. personal" : "e.g. work") : "name"
        field.target = self   // Return in the name field saves
        field.action = #selector(primaryClicked)
        pane.addSubview(field)
        nameField = field

        pane.addSubview(label("Pet", x: 24, y: y0 + 128, size: 12, weight: .medium))
        for (i, s) in Species.allCases.enumerated() {
            let tile = PickTile(frame: NSRect(x: 24 + CGFloat(i) * 76, y: y0 + 146, width: 70, height: 86))
            let thumb = OwlView.thumbnail(Look(species: s), size: 52)
            thumb.setFrameOrigin(NSPoint(x: 9, y: 6))
            tile.addSubview(thumb)
            let caption = label(s.label, x: 0, y: 62, size: 11, weight: .regular)
            caption.frame = NSRect(x: 0, y: 62, width: 70, height: 16)
            caption.alignment = .center
            tile.addSubview(caption)
            tile.onClick = { [weak self] in
                self?.look.species = s
                self?.updateLook()
            }
            pane.addSubview(tile)
            petTiles.append((tile, thumb))
        }
        pane.addSubview(label("Colour", x: 24, y: y0 + 240, size: 12, weight: .medium))
        for i in 0..<5 {
            let sw = PickTile(frame: NSRect(x: 20 + CGFloat(i) * 42, y: y0 + 258, width: 38, height: 38))
            sw.onClick = { [weak self] in
                self?.look.color = i
                self?.updateLook()
            }
            pane.addSubview(sw)
            swatches.append(sw)
        }

        let apps = PetController.surfaces.filter { controller?.surfaceOn($0.key) ?? true }.map { $0.label }
        let n = note(editing != nil ? "Changing the name or pet doesn't sign you out of anything."
                     : first ? "Claude Pet saves the logins you're using right now under this name."
                     : "Claude Pet saves your current logins, then signs you out of \(apps.joined(separator: " and ")) so you can log in to the new account.",
                     y: y0 + 304)
        pane.addSubview(n)
        noteLabel = n

        let by = y0 + 342
        let primary = PillButton(title: editing != nil ? "Save" : (first ? "Save" : "Add profile"), color: .controlAccentColor,
                                 frame: NSRect(x: SettingsWindow.paneW - 24 - 120, y: by, width: 120, height: 32))
        primary.onClick = { [weak self] in self?.primaryClicked() }
        pane.addSubview(primary)
        if let c = current {
            if !c.isCurrent {
                let use = PillButton(title: "Switch to it", color: .systemGreen,
                                     frame: NSRect(x: SettingsWindow.paneW - 24 - 120 - 8 - 120, y: by, width: 120, height: 32))
                let name = c.name
                use.onClick = { [weak self] in self?.controller?.perform(["use", name]) }
                pane.addSubview(use)
            }
        }
        updateLook()
        fit(height: by + 32 + 20)
    }

    func updateLook() {
        preview?.look = look
        for (i, s) in Species.allCases.enumerated() where i < petTiles.count {
            petTiles[i].tile.selected = s == look.species
            petTiles[i].thumb.look = Look(species: s, color: look.color)
        }
        for (i, sw) in swatches.enumerated() {
            sw.swatch = Look(species: look.species, color: i).body
            sw.selected = i == look.color
        }
    }

    @objc func primaryClicked() {
        guard let c = controller, let field = nameField else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.count > 10 {
            if name.count > 10 { noteLabel?.stringValue = "Keep the name to 10 characters or fewer." }
            NSSound.beep()
            window.makeFirstResponder(field)
            return
        }
        let look = self.look
        if let old = editing {
            if name != old {
                pendingSelect = name
                c.perform(["rename", old, name]) { look.save(for: name) }
            } else if look != Look.of(old) {
                look.save(for: old)   // just the pet: applies straight away, even in test mode
                c.refresh()
                c.say("✓ Saved \(old)")
            }
        } else {
            // adding signs you out, so get the window out of the way of the checklist bubble
            window.orderOut(nil)
            pendingSelect = name
            c.perform([accounts.isEmpty ? "init" : "add", name]) { look.save(for: name) }
        }
    }

    func deleteClicked(_ name: String) {
        guard let c = controller else { return }
        let other = accounts.first { $0.name != name }?.name
        var info = "Its saved logins are deleted from this Mac. This can't be undone."
        if accounts.first(where: { $0.name == name })?.isCurrent == true {
            info += other.map { "\n\nYou're using \(name) now, so Claude Pet switches to \($0) first." }
                ?? "\n\nIt's your only profile: Claude Pet forgets it, and your apps stay logged in."
        }
        let a = NSAlert()
        a.messageText = "Delete “\(name)”?"
        a.informativeText = info
        a.addButton(withTitle: "Delete").hasDestructiveAction = true
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { c.perform(["remove", name]) }
        }
    }

    // MARK: Pet

    func buildPet() {
        header("Pet", "How big your pet is on the desktop. Animals and colours are set per profile.")
        let step = PetController.sizeStep
        let steps = PetController.sizeSteps
        let sizeLabel = label("Size · \(steps[step].name) (\(Int(steps[step].scale * 100))%)", x: 24, y: 88, size: 13, weight: .medium)
        sizeLabel.frame.size.width = 300
        pane.addSubview(sizeLabel)

        // a real-size preview of the current pet
        let box = NSBox(frame: NSRect(x: 24, y: 164, width: SettingsWindow.paneW - 48, height: 210))
        box.boxType = .custom
        box.cornerRadius = 10
        box.borderWidth = 0
        box.fillColor = NSColor.labelColor.withAlphaComponent(0.05)
        pane.addSubview(box)
        let look = controller?.owl.look ?? Look()
        func placePreview(_ k: CGFloat) -> OwlView {
            let v = OwlView.thumbnail(look, size: round(124 * k))
            v.outlined = true
            v.setFrameOrigin(NSPoint(x: box.frame.midX - v.frame.width / 2, y: box.frame.midY - v.frame.height / 2))
            return v
        }
        var pv = placePreview(steps[step].scale)
        pane.addSubview(pv)

        let h = ActionHandler { [weak self] sender in
            guard let self = self, let slider = sender as? NSSlider else { return }
            let s = max(0, min(4, Int(slider.doubleValue.rounded())))
            sizeLabel.stringValue = "Size · \(steps[s].name) (\(Int(steps[s].scale * 100))%)"
            pv.removeFromSuperview()
            pv = placePreview(steps[s].scale)
            self.pane.addSubview(pv)
            self.controller?.setSize(step: s)
        }
        handlers.append(h)
        let slider = NSSlider(value: Double(step), minValue: 0, maxValue: 4, target: h, action: #selector(ActionHandler.fire(_:)))
        slider.numberOfTickMarks = 5
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.frame = NSRect(x: 24, y: 112, width: 300, height: 24)
        pane.addSubview(slider)
        // tick labels: the knob travels the slider's width minus its own (about 20pt)
        for (i, s) in steps.enumerated() {
            let l = label(s.name, x: 0, y: 138, size: 10, weight: .regular, secondary: true)
            let tickX = slider.frame.minX + 10 + CGFloat(i) * (slider.frame.width - 20) / 4
            l.setFrameOrigin(NSPoint(x: tickX - l.frame.width / 2, y: 138))
            pane.addSubview(l)
        }

        if #available(macOS 13, *) {
            checkbox("Start Claude Pet when I log in", y: 392, on: SMAppService.mainApp.status == .enabled) { [weak self] on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    self?.controller?.alert("Couldn't change the login setting", error.localizedDescription)
                    self?.render()
                }
            }
            pane.addSubview(note("You can also manage this in System Settings → General → Login Items.", y: 416))
        }
    }

    // MARK: Switching

    func buildSwitching() {
        guard let c = controller else { return }
        header("Switching", "What changes when you pick another profile.")
        pane.addSubview(label("Switch these apps", x: 24, y: 88, size: 13, weight: .medium))
        var y: CGFloat = 112
        for s in PetController.surfaces {
            let key = s.key
            checkbox(s.key == "desktop" ? "\(s.label) (quits and reopens it)" : s.label, y: y, on: c.surfaceOn(key)) { on in
                UserDefaults.standard.set(on, forKey: "surface.\(key)")
            }
            y += 26
        }
        y += 14
        checkbox("Ask before restarting the Claude desktop app", y: y,
                 on: !UserDefaults.standard.bool(forKey: "skipDesktopWarning")) { on in
            UserDefaults.standard.set(!on, forKey: "skipDesktopWarning")
        }
        pane.addSubview(note("Restarting the desktop app stops any chat or Cowork task running in it.", y: y + 24, height: 18))
        y += 60
        pane.addSubview(note("claude.ai in Chrome isn't switched here. Claude Pet for Chrome is coming soon.", y: y, height: 18))
        y += 36
        if c.devUnlocked {
            separator(y: y)
            checkbox("Test mode (don't really switch)", y: y + 14, on: c.testMode) { on in c.testMode = on }
            pane.addSubview(note("Switches are only simulated. Unlocked with the eye code; do it again to lock and hide this.",
                                 y: y + 38))
        }
    }

    // MARK: About

    func buildAbout() {
        // a fresh look when About opens (at most once a minute), then show what it found
        if let c = controller, !c.updating, c.update == nil, (c.lastCheck.map { -$0.timeIntervalSinceNow > 60 } ?? true) {
            c.checkForUpdates { [weak self] in if self?.section == .about { self?.render() } }
        }
        let pic = OwlView.thumbnail(controller?.owl.look ?? Look(), size: 96)
        pic.outlined = true
        pic.setFrameOrigin(NSPoint(x: 24, y: 24))
        pane.addSubview(pic)
        pane.addSubview(label("Claude Pet", x: 136, y: 36, size: 24, weight: .bold))
        let v = PetController.appVersion
        let status = controller.map { c in
            c.update.map { "Update available: \($0.latest)" }
                ?? (c.lastCheck == nil ? "Checking for updates…" : c.lastCheckFailed ? "Couldn't check right now" : "Up to date")
        } ?? ""
        pane.addSubview(label("Version \(v) · \(status)", x: 136, y: 70, size: 12, weight: .regular, secondary: true))
        if let c = controller {
            if let u = c.update {
                let now = PillButton(title: "Update to \(u.latest)", color: .systemGreen, frame: NSRect(x: 136, y: 92, width: 150, height: 28))
                now.onClick = { [weak c] in c?.startUpdate() }
                pane.addSubview(now)
            } else {
                let check = PillButton(title: "Check for updates", color: .systemGray, frame: NSRect(x: 136, y: 92, width: 150, height: 28))
                check.onClick = { [weak self, weak c, weak check] in
                    check?.title = "Checking…"
                    c?.checkForUpdates(userAsked: true) { self?.render() }
                }
                pane.addSubview(check)
            }
        }
        let body = NSTextField(wrappingLabelWithString:
            "Switches your Claude accounts in Claude Code and the Claude desktop app. Hover the pet and pick a " +
            "profile; drag it anywhere.\n\nA free, just-for-fun project from GeekyOwls. Not affiliated with Anthropic.")
        body.font = .systemFont(ofSize: 13)
        body.frame = NSRect(x: 24, y: 140, width: SettingsWindow.paneW - 48, height: 90)
        pane.addSubview(body)
        let site = PillButton(title: "geekyowls.com", color: .controlAccentColor, frame: NSRect(x: 24, y: 240, width: 140, height: 32))
        site.onClick = { NSWorkspace.shared.open(URL(string: "https://geekyowls.com")!) }
        pane.addSubview(site)

        separator(y: 296)
        pane.addSubview(note("Claude Pet is free. If it saves you time, you can support GeekyOwls (from $1).", y: 312, height: 18))
        let support = PillButton(title: "Support GeekyOwls ♥", color: .systemPink, frame: NSRect(x: 24, y: 338, width: 190, height: 32))
        support.onClick = { PetController.openSupport() }
        pane.addSubview(support)

        separator(y: 394)
        if let notes = controller?.update?.notes, !notes.isEmpty {
            pane.addSubview(note("What's new: \(notes)", y: 404, height: 32))
        }
        checkbox("Install updates automatically", y: 440, on: UserDefaults.standard.bool(forKey: "autoUpdate")) { on in
            UserDefaults.standard.set(on, forKey: "autoUpdate")
        }
        pane.addSubview(note("Claude Pet checks GitHub for a new version about once a day. Updates keep your profiles and settings.",
                             y: 464))
    }
}

/// A panel macOS doesn't push away from the menu bar: the pet's window is roomier than the pet
/// (headroom for animations), so the app keeps the visible pet on screen itself.
final class FreePanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// MARK: - Controller

final class PetController: NSObject {
    // claude.ai isn't switched here (Claude Pet for Chrome is a separate project)
    static let surfaces: [(key: String, label: String)] = [
        ("cli", "Claude Code (CLI)"),
        ("desktop", "Claude desktop app"),
    ]
    static let stateDir = NSHomeDirectory() + "/Library/Application Support/ClaudePet"

    let panel: NSPanel
    let owl: OwlView
    let bubblePanel: NSPanel
    let bubble: BubbleView
    var bubbleTimer: Timer?
    let pickerPanel: NSPanel
    var pickerMonitor: Any?
    var hoverTimer: Timer?
    var pickerWatch: Timer?
    var pickerAwayTicks = 0
    var eyeTaps: [(eye: Int, at: Date)] = []
    var accounts: [Account] = []
    var busy = false
    var stateSignature = ""

    static func floatingPanel(_ rect: NSRect) -> NSPanel {
        let p = FreePanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.hidesOnDeactivate = false
        p.isMovable = false
        return p
    }

    /// Pet sizes on the menu's slider: one step is 25% of the original (Medium). Small is the default.
    static let sizeSteps: [(scale: CGFloat, name: String)] = [
        (0.5, "Tiny"), (0.75, "Small"), (1, "Medium"), (1.25, "Large"), (1.5, "Huge"),
    ]

    static var sizeStep: Int {
        get {
            let d = UserDefaults.standard
            return d.object(forKey: "sizeStep") == nil ? 1 : max(0, min(4, d.integer(forKey: "sizeStep")))   // Small
        }
        set { UserDefaults.standard.set(newValue, forKey: "sizeStep") }
    }

    /// The main pet has no name tag (names show in the hover picker), except "click to set up"
    /// before the first profile and the "· test" reminder in test mode.
    static func wantsTag(name: String, test: Bool) -> Bool { name.isEmpty || test }

    static let petBottomMargin: CGFloat = 4

    /// The main pet's window: the pet plus headroom for flapping wings, the bounce hop and the
    /// outline's shadow (all transparent, so clicks there pass through to what's behind).
    static func petFrameSize(tag: Bool) -> NSSize {
        let k = sizeSteps[sizeStep].scale
        let base = OwlView.frameSize(petScale: k, minWidth: 0, withTag: tag)
        return NSSize(width: max(base.width + round(34 * k) + 8, tag ? 110 : 0),
                      height: base.height + round(14 * k) + petBottomMargin + 4)
    }

    override init() {
        let current = (try? String(contentsOfFile: PetController.stateDir + "/current", encoding: .utf8)) ?? ""
        let tag = PetController.wantsTag(name: current.trimmingCharacters(in: .whitespacesAndNewlines),
                                         test: UserDefaults.standard.bool(forKey: "testMode"))
        let size = PetController.petFrameSize(tag: tag)
        panel = PetController.floatingPanel(NSRect(origin: PetController.startOrigin(size), size: size))
        owl = OwlView(frame: NSRect(origin: .zero, size: size))
        owl.showsTag = tag
        owl.outlined = true
        owl.bottomMargin = PetController.petBottomMargin
        bubblePanel = PetController.floatingPanel(NSRect(x: 0, y: 0, width: 100, height: 30))
        bubble = BubbleView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        pickerPanel = PetController.floatingPanel(NSRect(x: 0, y: 0, width: 100, height: 30))
        super.init()

        panel.contentView = owl
        scaleOwl()
        bubblePanel.contentView = bubble
        bubblePanel.hasShadow = true

        owl.onClick = { [weak self] in self?.showPicker() }
        owl.onHover = { [weak self] inside in self?.owlHover(inside) }
        owl.onEyeClick = { [weak self] eye in self?.eyeTapped(eye) }
        owl.onMenu = { [weak self] event in self?.hidePicker(); self?.showMenu(event) }
        owl.onDrag = { [weak self] in
            guard let self = self else { return }
            self.hidePicker()
            self.placeBubble()
        }
        owl.clampOrigin = { [weak self] origin in self?.clampPet(origin) ?? origin }
        owl.onMoved = { [weak self] _ in self?.savePosition() }
        bubble.onClick = { [weak self] in
            let action = self?.bubbleAction
            self?.hideBubble()
            action?()
        }
    }

    func scaleOwl() {
        owl.frame = NSRect(origin: .zero, size: panel.frame.size)
        owl.petScale = PetController.sizeSteps[PetController.sizeStep].scale
    }

    /// Resize around the pet's feet (bottom centre), so it grows up and out from where it stands.
    func applySize() {
        let size = PetController.petFrameSize(tag: owl.showsTag)
        let f = panel.frame
        let origin = NSPoint(x: round(f.midX - size.width / 2), y: f.minY)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        scaleOwl()
        panel.setFrameOrigin(clampPet(panel.frame.origin, followMouse: false))
        savePosition()
        if bubblePanel.isVisible { placeBubble() }
    }

    func updateMainTag() {
        let want = PetController.wantsTag(name: owl.name, test: owl.testMode)
        guard want != owl.showsTag else { return }
        owl.showsTag = want
        applySize()
    }

    /// Saved as where the pet's feet stand (bottom centre), so changing its size never makes it drift.
    func savePosition() {
        UserDefaults.standard.set(Double(panel.frame.midX), forKey: "petCX")
        UserDefaults.standard.set(Double(panel.frame.minY), forKey: "petY")
    }

    static func startOrigin(_ size: NSSize) -> NSPoint {
        let d = UserDefaults.standard
        let cx: Double? = d.object(forKey: "petCX") != nil ? d.double(forKey: "petCX")
            : d.object(forKey: "petX") != nil ? d.double(forKey: "petX") + 62 : nil   // older builds saved the corner
        if let cx = cx {
            let saved = NSPoint(x: round(CGFloat(cx) - size.width / 2), y: CGFloat(d.double(forKey: "petY")))
            let rect = NSRect(origin: saved, size: size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) { return saved }
        }
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        return NSPoint(x: vf.maxX - size.width - 24, y: vf.minY + 24)
    }

    func start() {
        owl.testMode = testMode
        // a pet saved under the Dock or off a screen that's gone comes back into reach
        panel.setFrameOrigin(clampPet(panel.frame.origin, followMouse: false))
        savePosition()
        panel.orderFrontRegardless()
        refresh()
        scheduleBlink()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self, self.busy else { return }
            self.owl.phase += 0.25
        }
        // updates: a first look shortly after launch, then about once a day
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkForUpdates() }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.checkForUpdates() }
        // pick up switches made from the terminal: cheap file check, full refresh only on change
        stateSignature = PetController.readStateSignature()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self, !self.busy else { return }
            let sig = PetController.readStateSignature()
            if sig != self.stateSignature {
                self.stateSignature = sig
                self.refresh()
            }
        }
    }

    /// The current account plus the saved account names, straight from the state folder.
    static func readStateSignature() -> String {
        let fm = FileManager.default
        let current = (try? String(contentsOfFile: stateDir + "/current", encoding: .utf8)) ?? ""
        let names = ((try? fm.contentsOfDirectory(atPath: stateDir + "/profiles")) ?? []).sorted()
        return current.trimmingCharacters(in: .whitespacesAndNewlines) + "|" + names.joined(separator: ",")
    }

    func scheduleBlink() {
        Timer.scheduledTimer(withTimeInterval: Double.random(in: 2.5...6.0), repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if !self.busy {
                self.owl.eyesClosed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { self.owl.eyesClosed = false }
            }
            self.scheduleBlink()
        }
    }

    // MARK: state

    func refresh() {
        Switcher.run(["list", "--porcelain"]) { [weak self] status, out, _ in
            guard let self = self else { return }
            guard status == 0 else { self.owl.name = ""; return }
            self.accounts = out.split(separator: "\n").compactMap { line -> Account? in
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard f.count >= 2 else { return nil }
                return Account(name: f[1], email: f.count > 2 ? f[2] : "", isCurrent: f[0] == "1",
                               look: Look.of(f[1]))
            }
            let current = self.accounts.first(where: { $0.isCurrent })
            self.owl.name = current?.name ?? ""
            self.updateMainTag()
            self.owl.look = current?.look ?? Look()
            self.settings?.accountsChanged()
        }
    }

    func surfaceOn(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: "surface.\(key)") as? Bool ?? true
    }

    func onlyArgs() -> [String]? {
        let on = PetController.surfaces.map { $0.key }.filter { surfaceOn($0) }
        if on.isEmpty { return nil }
        // always explicit: the script's default would include the browser
        return ["--only", on.joined(separator: ",")]
    }

    /// args is always [command, name]: use, add, init or remove.
    /// Secret toggle for test mode: left eye ×3, then right eye ×3, within 3 seconds.
    func eyeTapped(_ eye: Int) {
        let now = Date()
        eyeTaps.append((eye, now))
        eyeTaps = Array(eyeTaps.filter { now.timeIntervalSince($0.at) <= 3 }.suffix(6))
        if eyeTaps.map({ $0.eye }) == [0, 0, 0, 1, 1, 1] {
            eyeTaps = []
            hidePicker()
            // unlocking shows the Test mode switch (Settings → Switching) and turns it on; locking hides it and turns it off
            devUnlocked = !devUnlocked
            testMode = devUnlocked
            if settings?.window.isVisible == true { settings?.render() }
            say(devUnlocked ? "🔓 Test mode unlocked and on\nSwitches are only simulated. Toggle it under Settings → Switching."
                            : "🔒 Test mode locked and off\nSwitches are real again.")
        }
    }

    var devUnlocked: Bool {
        get { UserDefaults.standard.bool(forKey: "devUnlocked") }
        set { UserDefaults.standard.set(newValue, forKey: "devUnlocked") }
    }

    /// Test mode (hidden, see eyeTapped): switches are only simulated. For trying the pet without touching real logins.
    var testMode: Bool {
        get { UserDefaults.standard.bool(forKey: "testMode") }
        set {
            UserDefaults.standard.set(newValue, forKey: "testMode")
            owl.testMode = newValue
            updateMainTag()
        }
    }

    /// Switching the desktop app quits it. If it's open (and would actually change), say so first,
    /// with a "Don't ask again" box.
    func confirmDesktopRestart(_ target: String) -> Bool {
        let d = UserDefaults.standard
        guard surfaceOn("desktop"), !d.bool(forKey: "skipDesktopWarning") else { return true }
        let running = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.anthropic.claudefordesktop"
        }
        let onDesktop = (try? String(contentsOfFile: PetController.stateDir + "/current.desktop", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard running, onDesktop != target else { return true }

        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "The Claude app will restart"
        a.informativeText = "To switch it to \(target), Claude Pet quits the Claude desktop app and opens it again. " +
            "Any chat or Cowork task running there will stop."
        a.addButton(withTitle: "Switch")
        a.addButton(withTitle: "Cancel")
        a.showsSuppressionButton = true
        a.suppressionButton?.title = "Don't ask again"
        let ok = a.runModal() == .alertFirstButtonReturn
        if ok && a.suppressionButton?.state == .on { d.set(true, forKey: "skipDesktopWarning") }
        return ok
    }

    /// Runs a script command with progress/result bubbles. `then` runs only after a real success
    /// (not in test mode), e.g. to save the pet chosen for a new account.
    func perform(_ args: [String], then: (() -> Void)? = nil) {
        guard !busy else { NSSound.beep(); return }
        if let u = update, u.required {
            say("Please update Claude Pet first\nThis version has a known problem, so switching is paused. Click to update to \(u.latest).",
                error: true, seconds: nil) { [weak self] in self?.startUpdate() }
            return
        }
        guard let only = onlyArgs() else {
            say("Nothing to switch\nTurn on at least one app under Settings → Switching.", error: true)
            return
        }
        let cmd = args[0], name = args[1]
        let newName = args.count > 2 ? args[2] : ""   // rename only
        // removing the account in use moves to this one first (same pick as the script)
        let fallback = accounts.first { $0.name != name }?.name
        let removingCurrent = cmd == "remove" && fallback != nil
            && accounts.contains { $0.name == name && $0.isCurrent }
        let switchTarget = (cmd == "use" || cmd == "add") ? name : (removingCurrent ? fallback : nil)
        if let t = switchTarget, !confirmDesktopRestart(t) { return }
        busy = true
        owl.busy = true
        if cmd == "use" { owl.bounce() }   // "got it" as soon as a profile is picked
        switch cmd {
        case "use": say("Switching to \(name)…", seconds: nil)
        case "add": say("Adding \(name)…", seconds: nil)
        case "init": say("Saving your logins as \(name)…", seconds: nil)
        case "rename": say("Renaming \(name) to \(newName)…", seconds: nil)
        default: say("Deleting \(name)…", seconds: nil)
        }
        if testMode {
            // the script never runs: nothing on the Mac changes, you just see what would happen
            let apps = PetController.surfaces.filter { surfaceOn($0.key) }.map { "• " + $0.label }
            let what = ["use": "switch to \(name)", "add": "add \(name) and sign you out of:",
                        "init": "save your current logins as \(name)",
                        "rename": "rename \(name) to \(newName)"][cmd]
                ?? (removingCurrent ? "switch to \(fallback ?? "") and delete \(name)" : "delete \(name)")
            let text = (["🧪 Test mode: would \(what)"] + (cmd == "use" || cmd == "add" ? apps : [])
                        + ["Nothing was changed."]).joined(separator: "\n")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self = self else { return }
                self.busy = false
                self.owl.busy = false
                if cmd == "use" { self.owl.cheer() }
                self.say(text, seconds: 6)
            }
            return
        }
        Switcher.run(only + args) { [weak self] status, _, err in
            guard let self = self else { return }
            self.busy = false
            self.owl.busy = false
            let lines = err.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if status == 127 {
                self.hideBubble()
                self.alert("Claude Pet can't find its script", lines.joined(separator: "\n") +
                           "\n\nReinstall with: claude-pet install-pet (or /claude-pet:setup in Claude Code).")
            } else if status != 0 {
                let title = ["use": "Couldn't switch", "add": "Couldn't add \(name)",
                             "init": "Couldn't save \(name)", "rename": "Couldn't rename \(name)"][cmd]
                    ?? "Couldn't delete \(name)"
                let detail = lines.map { $0.hasPrefix("claude-pet: ") ? String($0.dropFirst(12)) : $0 }
                self.say(([title] + (detail.isEmpty ? ["claude-pet exited with code \(status)."] : detail))
                         .joined(separator: "\n"), error: true)
            } else {
                then?()
                self.reportSuccess(cmd, name, lines, newName: newName, movedTo: removingCurrent ? fallback : nil)
            }
            self.refresh()
        }
    }

    func reportSuccess(_ cmd: String, _ name: String, _ lines: [String], newName: String, movedTo: String?) {
        // anything the script logged that isn't a ✓ step or its own hint is a warning worth showing
        let warnings = lines.filter { !$0.hasPrefix("✓") && !$0.hasPrefix("Now log in") }
        switch cmd {
        case "add":
            var msg = ["Now log in to \(name) in:"]
            for s in PetController.surfaces where surfaceOn(s.key) {
                msg.append(s.key == "cli" ? "• Claude Code — run claude, then /login" : "• \(s.label)")
            }
            msg.append("Claude Pet saves it when you switch away.")
            say((msg + warnings).joined(separator: "\n"), seconds: nil)
        case "init":
            say((["✓ Saved as \(name)", "Hover me and click + to add the next one."] + warnings)
                .joined(separator: "\n"), seconds: nil)
        case "rename":
            say((["✓ Renamed \(name) to \(newName)"] + warnings).joined(separator: "\n"))
        case "remove":
            var msg = ["✓ Deleted \(name)"]
            if let t = movedTo {
                msg.append("You're on \(t) now.")
                if lines.contains(where: { $0.hasPrefix("✓ Claude Code") }) { msg.append("Restart running claude sessions.") }
            }
            say((msg + warnings).joined(separator: "\n"), seconds: 6)
        default:
            let switched = lines.contains { $0.hasPrefix("✓") }
            if switched { owl.cheer() }
            var msg = [switched ? "✓ Switched to \(name)" : "Already on \(name)"]
            if lines.contains(where: { $0.hasPrefix("✓ Claude Code") }) {
                msg.append("Restart running claude sessions.")
            }
            say((msg + warnings).joined(separator: "\n"), seconds: warnings.isEmpty ? 5 : 10)
        }
    }

    // MARK: picker

    /// Small pets in the picker are always this size (a little smaller than a Tiny main pet),
    /// whatever size the main pet is.
    static let miniScale: CGFloat = 0.42

    /// Hovering the owl briefly opens the picker. It closes once the pointer has been away from both
    /// the owl and the picker for half a second. (A geometry check, because the transparent gaps
    /// between the small owls don't receive mouse events.)
    func owlHover(_ inside: Bool) {
        hoverTimer?.invalidate()
        hoverTimer = nil
        guard inside, !pickerPanel.isVisible, !busy, !accounts.isEmpty, NSEvent.pressedMouseButtons == 0 else { return }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in self?.showPicker() }
    }

    func watchPickerPointer() {
        pickerAwayTicks = 0
        pickerWatch?.invalidate()
        pickerWatch = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let zone = self.panel.frame.union(self.pickerPanel.frame).insetBy(dx: -16, dy: -16)
            if zone.contains(NSEvent.mouseLocation) {
                self.pickerAwayTicks = 0
            } else {
                self.pickerAwayTicks += 1
                if self.pickerAwayTicks >= 5 { self.hidePicker() }
            }
        }
    }

    /// The owl splits into one small owl per account (in each account's colour), plus a "+" to add one.
    /// Keeps a dragged (or restored) pet reachable: its visible part may go right up to the menu bar
    /// and down to the Dock, never under them, and at most half of it past the left or right edge.
    /// Uses the screen under the pointer, so it can still be dragged onto another display.
    func clampPet(_ origin: NSPoint, followMouse: Bool = true) -> NSPoint {
        let f = panel.frame
        let mouse = NSEvent.mouseLocation
        let screen = (followMouse ? NSScreen.screens.first { $0.frame.contains(mouse) } : nil)
            ?? NSScreen.screens.first { $0.frame.contains(NSPoint(x: origin.x + f.width / 2, y: origin.y + f.height / 2)) }
            ?? panel.screen ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return origin }
        let pet = visiblePetFrame
        let left = pet.minX - f.minX, right = f.maxX - pet.maxX   // transparent room around the pet
        let below = pet.minY - f.minY, above = f.maxY - pet.maxY
        var o = origin
        o.y = min(max(o.y, vf.minY - below), vf.maxY - above - pet.height)
        o.x = min(max(o.x, vf.minX - left - pet.width / 2), vf.maxX - right - pet.width / 2)
        return o
    }

    /// The pet's drawn area on screen (its window also has headroom for animations).
    var visiblePetFrame: NSRect {
        let k = PetController.sizeSteps[PetController.sizeStep].scale
        let f = panel.frame
        let w = round(124 * k), h = round(120 * k) + owl.tagHeight
        return NSRect(x: f.midX - w / 2, y: f.minY + PetController.petBottomMargin, width: w, height: h)
    }

    func showPicker() {
        hoverTimer?.invalidate()
        if pickerMonitor != nil { return }   // already open
        if busy { NSSound.beep(); return }
        if accounts.isEmpty { manageAccounts(adding: true); return }

        let s = PetController.miniScale
        let tagFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let mini = OwlView.frameSize(petScale: s, minWidth: 0)
        let gap: CGFloat = 3, margin: CGFloat = 3
        // ♥, + and the gear: three stacked exactly as tall as a small pet (which never changes size)
        let plusD = floor((mini.height - gap * 2) / 3)
        let gapToPet: CGFloat = 4
        let f = visiblePetFrame   // measure from the pet itself, not its (roomier) window
        let vf = (NSScreen.screens.first { $0.frame.contains(NSPoint(x: f.midX, y: f.midY)) }
                  ?? panel.screen ?? NSScreen.main)?.visibleFrame ?? f
        // pushed against (or past) a side of the screen: a vertical column beside the pet instead of a row
        let atRight = f.maxX > vf.maxX - 6, atLeft = f.minX < vf.minX + 6
        let vertical = atRight || atLeft
        // in a row the active profile goes last, next to "+" and the gear; in a column, first (just
        // under them)
        let others = accounts.filter { !$0.isCurrent }, current = accounts.filter { $0.isCurrent }
        let ordered = vertical ? current + others : others + current
        // each slot is as wide as its own name tag (or the pet, if wider)
        let slotW = ordered.map { a -> CGFloat in
            let text = (a.isCurrent ? "✓ " : "") + a.name
            return max(mini.width, ceil((text as NSString).size(withAttributes: [.font: tagFont]).width) + 10)
        }
        let n = CGFloat(ordered.count)

        var width: CGFloat, height: CGFloat, x: CGFloat, y: CGFloat
        var slots: [NSRect] = []                       // where each small pet ends up, panel coordinates
        var plusAt = NSPoint.zero, gearAt = NSPoint.zero, heartAt = NSPoint.zero
        var captionAt: [(NSSize) -> NSPoint] = []      // where its email label goes, given the label size
        var buttonCaptionAt: (NSRect, NSSize) -> NSPoint = { b, _ in b.origin }   // a button's label
        let colW = max(slotW.max() ?? mini.width, plusD * 3 + gap * 2)
        let captionRoom: CGFloat = 200                 // beside a column, for the email label

        if vertical {
            // "+" and the gear level with the pet, then the active profile, then the others. Runs
            // down from the pet's top; near the bottom of the screen it flips and runs up from its feet.
            width = margin * 2 + colW + captionRoom
            height = margin * 2 + plusD + n * (mini.height + gap)
            let colX = atRight ? width - margin - colW : margin
            x = atRight ? f.minX - gapToPet - (colX + colW) : f.maxX + gapToPet - colX
            let downward = f.maxY - height >= vf.minY
            y = downward ? f.maxY - height : max(vf.minY, min(f.minY, vf.maxY - height))
            let buttonsX = colX + (colW - (plusD * 3 + gap * 2)) / 2
            let buttonsY = downward ? height - margin - plusD : margin
            plusAt = NSPoint(x: buttonsX, y: buttonsY)
            gearAt = NSPoint(x: buttonsX + plusD + gap, y: buttonsY)
            heartAt = NSPoint(x: buttonsX + (plusD + gap) * 2, y: buttonsY)
            buttonCaptionAt = { b, size in
                NSPoint(x: atRight ? colX - 2 - size.width : colX + colW + 2, y: b.midY - size.height / 2)
            }
            for i in 0..<ordered.count {
                let step = CGFloat(i) * (mini.height + gap)
                let slotY = downward ? buttonsY - gap - mini.height - step : buttonsY + plusD + gap + step
                let slot = NSRect(x: colX, y: slotY, width: colW, height: mini.height)
                slots.append(slot)
                captionAt.append { size in
                    NSPoint(x: atRight ? colX - 2 - size.width : colX + colW + 2, y: slot.midY - size.height / 2)
                }
            }
        } else {
            // a row a fixed gap above the pet (below it at the top of the screen), lined up with its
            // outer edge so it grows towards the middle of the screen; "+" and the gear on the right
            let rowW = slotW.reduce(0, +) + n * gap
            let captionH: CGFloat = 30   // room above the small pets for the email label
            let rowPartW = margin * 2 + rowW + plusD   // the pets and buttons; the row lines up by this
            height = mini.height + captionH
            let above = f.maxY + gapToPet + height <= vf.maxY
            let growLeft = f.midX > vf.midX
            x = max(vf.minX + 4, min(growLeft ? f.maxX - rowPartW : f.minX, vf.maxX - rowPartW - 4))
            // extra (transparent) room to the right of the buttons for their labels, as far as the
            // screen allows, so a label doesn't cover the small pets
            let labelRoom = max(0, min(160, vf.maxX - 2 - (x + rowPartW)))
            width = rowPartW + labelRoom
            y = above ? f.maxY + gapToPet : f.minY - height - gapToPet
            var slotX = margin
            for i in 0..<ordered.count {
                let slot = NSRect(x: slotX, y: 0, width: slotW[i], height: mini.height)
                slots.append(slot)
                let rowRight = margin + slotW.reduce(0, +) + n * gap   // keep the label clear of the buttons
                captionAt.append { size in
                    NSPoint(x: max(0, min(slot.midX - size.width / 2, rowRight - size.width)), y: mini.height + 2)
                }
                slotX += slotW[i] + gap
            }
            // ♥, + and the gear stacked on the right, level with the small pets
            gearAt = NSPoint(x: margin + rowW, y: 0)
            plusAt = NSPoint(x: margin + rowW, y: plusD + gap)
            heartAt = NSPoint(x: margin + rowW, y: (plusD + gap) * 2)
            let w = width
            let band = mini.height + 2   // the empty strip above the small pets
            buttonCaptionAt = { b, size in
                // right of the button when it fits; else left of it if it fits there whole; else in the
                // strip above the stack, so a label never covers the button it describes
                let right = b.maxX + 4, left = b.minX - 4 - size.width
                if right + size.width <= w { return NSPoint(x: right, y: b.midY - size.height / 2) }
                if left >= 0 { return NSPoint(x: left, y: b.midY - size.height / 2) }
                return NSPoint(x: max(0, b.maxX - size.width), y: band)
            }
        }
        pickerPanel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.wantsLayer = true
        pickerPanel.contentView = content

        // everything starts tucked into the big pet and hops out to its place
        let home = NSPoint(x: f.midX - x - mini.width / 2, y: f.midY - y - mini.height / 2)
        var items: [(view: NSView, target: NSPoint)] = []
        // hovering a small pet shows its email next to it (tooltips don't show for a background app)
        let caption = BubbleView(frame: .zero)
        caption.isHidden = true
        for (i, a) in ordered.enumerated() {
            let slot = slots[i]
            let v = OwlView(frame: NSRect(origin: home, size: slot.size))
            v.petScale = s
            v.outlined = true
            v.name = a.name
            v.checked = a.isCurrent
            v.look = a.look
            v.draggable = false
            let name = a.name, isCurrent = a.isCurrent, email = a.email, place = captionAt[i], w = width
            v.onHover = { inside in
                guard inside, !email.isEmpty else { caption.isHidden = true; return }
                caption.text = email
                var size = caption.fittingSize()
                size.width = min(size.width, w)
                caption.frame = NSRect(origin: place(size), size: size)
                caption.isHidden = false
            }
            v.onClick = { [weak self] in
                guard let self = self else { return }
                self.hidePicker()
                if !isCurrent { self.perform(["use", name]) }
            }
            items.append((v, slot.origin))
        }
        let size = NSSize(width: plusD, height: plusD)
        let plus = RoundButton(symbol: "plus", tip: "Add profile", frame: NSRect(origin: home, size: size))
        plus.pointSize = round(plusD * 0.5)
        plus.onClick = { [weak self] _ in
            self?.hidePicker()
            self?.manageAccounts(adding: true)
        }
        items.append((plus, plusAt))
        let gear = RoundButton(symbol: "gearshape.fill", tip: "Settings", frame: NSRect(origin: home, size: size))
        gear.badge = update != nil
        gear.pointSize = round(plusD * 0.5)
        // with an update waiting, the gear goes straight to About, where the update is
        gear.onClick = { [weak self] _ in self?.openSettings(self?.update != nil ? .about : nil) }
        items.append((gear, gearAt))
        let heart = RoundButton(symbol: "heart.fill", tip: "Support GeekyOwls", frame: NSRect(origin: home, size: size))
        heart.hoverColor = .systemPink
        heart.pointSize = round(plusD * 0.5)
        heart.onClick = { [weak self] _ in
            self?.hidePicker()
            PetController.openSupport()
        }
        items.append((heart, heartAt))
        // hover labels for the buttons, shown where they'll end up (not where they start the hop)
        for (button, at, text) in [(plus, plusAt, "Add a profile"), (gear, gearAt, update != nil ? "Settings · update available" : "Settings"),
                                   (heart, heartAt, "Support the developer")] {
            let place = buttonCaptionAt, target = NSRect(origin: at, size: size)
            button.onHover = { inside in
                guard inside else { caption.isHidden = true; return }
                caption.text = text
                let size = caption.fittingSize()
                caption.frame = NSRect(origin: place(target, size), size: size)
                caption.isHidden = false
            }
        }

        for (i, item) in items.enumerated() {
            item.view.alphaValue = 0
            content.addSubview(item.view)
            let v = item.view, target = item.target
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(i)) {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.32
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.5, 0.64, 1)
                    v.animator().setFrameOrigin(target)
                    v.animator().alphaValue = 1
                }
            }
        }
        content.addSubview(caption)
        pickerPanel.alphaValue = 1
        pickerPanel.orderFrontRegardless()
        watchPickerPointer()

        // a click anywhere else closes it
        pickerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hidePicker()
        }
    }

    func hidePicker() {
        if let m = pickerMonitor { NSEvent.removeMonitor(m) }
        pickerMonitor = nil
        pickerWatch?.invalidate()
        pickerWatch = nil
        guard pickerPanel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            pickerPanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self, self.pickerMonitor == nil else { return }   // reopened meanwhile
            self.pickerPanel.orderOut(nil)
            self.pickerPanel.alphaValue = 1
        })
    }

    // MARK: bubble

    /// Show a note next to the owl. First line is the title. seconds == nil keeps it until clicked.
    func say(_ text: String, error: Bool = false, seconds: Double? = 5, onClick: (() -> Void)? = nil) {
        bubbleTimer?.invalidate()
        bubbleTimer = nil
        bubbleAction = onClick
        bubble.text = text
        bubble.isError = error
        placeBubble()
        bubblePanel.orderFrontRegardless()
        // errors stay until clicked, unless they're clickable
        if let s = seconds, !error || onClick != nil {
            bubbleTimer = Timer.scheduledTimer(withTimeInterval: s, repeats: false) { [weak self] _ in
                self?.hideBubble()
            }
        }
    }

    var bubbleAction: (() -> Void)?   // what clicking the bubble does besides closing it

    func hideBubble() {
        bubbleAction = nil
        bubbleTimer?.invalidate()
        bubbleTimer = nil
        bubblePanel.orderOut(nil)
    }

    /// Beside the owl, on whichever side has more room, level with its body.
    func placeBubble() {
        let size = bubble.fittingSize()
        let f = panel.frame
        let vf = (panel.screen ?? NSScreen.main)?.visibleFrame ?? f
        let inset: CGFloat = 8   // the owl drawing has some empty margin; tuck the bubble into it
        var x = f.midX > vf.midX ? f.minX - size.width + inset : f.maxX - inset
        var y = f.minY + f.height * 0.55 - size.height / 2
        x = max(vf.minX + 4, min(x, vf.maxX - size.width - 4))
        y = max(vf.minY + 4, min(y, vf.maxY - size.height - 4))
        bubblePanel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        bubble.frame = NSRect(origin: .zero, size: size)
        bubble.needsDisplay = true
        bubblePanel.invalidateShadow()
    }

    // MARK: dialogs

    func alert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }

    func confirm(_ title: String, _ message: String, _ ok: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: ok)
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    // MARK: updates

    /// Published in the public repo. {"latest": "1.2.0", "minimum": "1.0.0", "notes": "…"}. Below
    /// `minimum`, switching is paused until the user updates (for bugs that could harm logins).
    static let updateFeed = URL(string: "https://raw.githubusercontent.com/geekyowlshq/claude-pet/main/update.json")!
    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    var update: (latest: String, notes: String, required: Bool)?
    var updating = false
    var updateProcess: Process?   // kept so we hear back if the update stops early
    var lastCheckFailed = false
    var lastCheck: Date?   // when the feed last answered (or failed)

    /// "1.10.0" > "1.9.2": compares dotted numbers.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// Reads the feed (a plain download of one small file: nothing about the user is sent).
    /// Quiet unless there's something new; `userAsked` also reports "up to date" and failures.
    func checkForUpdates(userAsked: Bool = false, done: (() -> Void)? = nil) {
        let feed = UserDefaults.standard.string(forKey: "updateFeed").flatMap(URL.init(string:)) ?? PetController.updateFeed
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("ClaudePet/\(PetController.appVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let ok = (response as? HTTPURLResponse).map { $0.statusCode == 200 } ?? (data != nil)
            let json = ok ? data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } : nil
            DispatchQueue.main.async { [weak self] in
                self?.handleFeed(json, userAsked: userAsked)
                done?()
            }
        }.resume()
    }

    func handleFeed(_ json: [String: Any]?, userAsked: Bool) {
        lastCheckFailed = json == nil
        lastCheck = Date()
        guard let j = json, let latest = j["latest"] as? String else {
            // not the user's problem (offline, GitHub busy): a calm note, not a red error
            if userAsked { say("Couldn't check for updates right now\nTry again later.", seconds: 6) }
            return
        }
        let current = PetController.appVersion
        guard PetController.isNewer(latest, than: current) else {
            update = nil
            if userAsked { say("✓ Claude Pet \(current) is up to date") }
            return
        }
        let minimum = j["minimum"] as? String ?? "0"
        let notes = j["notes"] as? String ?? ""
        update = (latest, notes, PetController.isNewer(minimum, than: current))
        let d = UserDefaults.standard
        if d.bool(forKey: "autoUpdate") && !(update?.required ?? false) && !busy {
            startUpdate()
            return
        }
        // tell once per new version (always when it's required, or when asked)
        if userAsked || update?.required == true || d.string(forKey: "toldAboutVersion") != latest {
            d.set(latest, forKey: "toldAboutVersion")
            let text = (update?.required == true ? ["Please update Claude Pet to \(latest)", "This version has a known problem."]
                                                 : ["Update available: \(latest)"])
                + (notes.isEmpty ? [] : [notes]) + ["Click here to update."]
            say(text.joined(separator: "\n"), error: update?.required == true, seconds: update?.required == true ? nil : 15) {
                [weak self] in self?.startUpdate()
            }
        }
        if settings?.window.isVisible == true { settings?.render() }
    }

    /// Runs `claude-pet self-update` in the background. It rebuilds and relaunches the pet, which
    /// replaces this process; its output goes to ~/Library/Logs/ClaudePet-update.log.
    func startUpdate() {
        guard !updating else {
            say("Already updating…\nI'll restart by myself when it's done.")
            return
        }
        updating = true
        hidePicker()
        let target = update?.latest ?? "the latest version"
        say("Updating Claude Pet to \(target)…\nI'll restart by myself in a minute or two.", seconds: nil)
        let logDir = NSHomeDirectory() + "/Library/Logs"
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        let logPath = logDir + "/ClaudePet-update.log"
        FileManager.default.createFile(atPath: logPath, contents: Data("Claude Pet update to \(target), \(Date())\n".utf8))
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [Switcher.scriptPath, "self-update"]
        if let h = FileHandle(forWritingAtPath: logPath) {
            h.seekToEndOfFile()
            proc.standardOutput = h
            proc.standardError = h
        }
        // A successful update quits this pet and starts the new one, so we only hear back here when
        // it didn't get that far.
        proc.terminationHandler = { p in
            let status = p.terminationStatus
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.updating = false
                self.updateProcess = nil
                self.say(status == 0 ? "The update finished, but I didn't restart\nClick to see what happened."
                                     : "The update didn't finish\nClick to see what happened.", error: true) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
                }
            }
        }
        do {
            try proc.run()   // it outlives this app when the new pet replaces it
            updateProcess = proc
        } catch {
            updating = false
            say("Couldn't start the update\n\(error.localizedDescription)", error: true)
        }
    }

    // MARK: settings window

    var settings: SettingsWindow?

    /// Open Settings; `adding` opens the Profiles page on a new profile.
    func openSettings(_ section: SettingsWindow.Section? = nil, adding: Bool = false) {
        hidePicker()
        if settings == nil { settings = SettingsWindow(controller: self) }
        // opens on Profiles unless asked otherwise; if it's already open, it just comes to the front
        let open = settings?.window.isVisible == true
        settings?.show(section ?? (open ? nil : .profiles), adding: adding)
    }

    func manageAccounts(adding: Bool = false) { openSettings(.profiles, adding: adding) }

    func setSize(step: Int) {
        guard step != PetController.sizeStep else { return }
        PetController.sizeStep = step
        applySize()
    }

    // MARK: menu

    func menuItem(_ title: String, _ action: Selector?, _ obj: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = obj
        return item
    }

    /// Right-click on the pet: just Settings and Quit (switching lives in the hover row).
    func showMenu(_ event: NSEvent) {
        let m = NSMenu()
        let open = menuItem("Settings…", #selector(settingsAction))
        open.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        m.addItem(open)
        let support = menuItem("Support GeekyOwls…", #selector(supportAction))
        support.image = NSImage(systemSymbolName: "heart", accessibilityDescription: nil)
        m.addItem(support)
        m.addItem(.separator())
        let quit = menuItem("Quit Claude Pet", #selector(quitAction))
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        m.addItem(quit)
        NSMenu.popUpContextMenu(m, with: event, for: owl)
    }

    @objc func settingsAction() { openSettings() }
    @objc func supportAction() { PetController.openSupport() }

    /// A Dodo Payments link: pay what you like, from $1.
    static func openSupport() { NSWorkspace.shared.open(URL(string: "https://dodo.pe/supportgeekyowls")!) }
    @objc func quitAction() { NSApp.terminate(nil) }
}

// MARK: - main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = PetController()
controller.start()
app.run()
