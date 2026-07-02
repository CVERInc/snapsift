#if os(macOS)
import AppKit
import Signet

// snapsift app icon: a fanned stack of photo cards on the reef ground — the
// back frames dim (the burst), the front card mint-bright with a teal keeper
// star (the one you keep). Drawn 2D; Signet's CVERAppIcon owns the squircle,
// sheen and .icns packaging so every CVER app mints its icon the same way.
//
//   swift run SnapsiftIcon           # → Assets/AppIcon.icns + Assets/AppIcon-1024.png

func hex(_ v: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
            green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255, alpha: alpha)
}

// The canonical reef palette (Signet ReefTheme literals).
let ground = hex(0x04181a)
let deep   = hex(0x052f30)
let teal   = hex(0x0a8c8e)
let mint   = hex(0xaceace)
let text   = hex(0xe6f4f3)

let side: CGFloat = 880   // foreground square handed to CVERAppIcon.compose

let foreground = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
    // Ground with a soft radial teal glow behind the stack.
    ground.setFill()
    NSRect(x: 0, y: 0, width: side, height: side).fill()
    NSGradient(starting: teal.withAlphaComponent(0.35), ending: ground.withAlphaComponent(0))?
        .draw(fromCenter: NSPoint(x: side * 0.5, y: side * 0.46), radius: 0,
              toCenter: NSPoint(x: side * 0.5, y: side * 0.46), radius: side * 0.62,
              options: [])

    // One photo card: rounded rect with border + inner "photo" area.
    func card(center: NSPoint, size: NSSize, angle: CGFloat,
              fill: NSColor, border: NSColor, borderWidth: CGFloat) {
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: angle * .pi / 180)
        let r = NSRect(x: -size.width / 2, y: -size.height / 2,
                       width: size.width, height: size.height)
        let path = NSBezierPath(roundedRect: r, xRadius: 42, yRadius: 42)
        // Drop shadow so the fan reads as depth.
        ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34,
                      color: NSColor.black.withAlphaComponent(0.55).cgColor)
        fill.setFill(); path.fill()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        border.setStroke(); path.lineWidth = borderWidth; path.stroke()
        ctx.restoreGState()
    }

    let cardSize = NSSize(width: side * 0.52, height: side * 0.40)
    let cx = side * 0.5, cy = side * 0.47

    // The burst: two dim cards fanned behind.
    card(center: NSPoint(x: cx - side * 0.075, y: cy + side * 0.02),
         size: cardSize, angle: 12,
         fill: deep, border: mint.withAlphaComponent(0.22), borderWidth: 6)
    card(center: NSPoint(x: cx + side * 0.075, y: cy + side * 0.005),
         size: cardSize, angle: -9,
         fill: deep, border: mint.withAlphaComponent(0.22), borderWidth: 6)

    // The keeper: front card, bright, teal-rimmed.
    card(center: NSPoint(x: cx, y: cy - side * 0.045),
         size: NSSize(width: cardSize.width * 1.06, height: cardSize.height * 1.06),
         angle: 2.5,
         fill: mint, border: teal, borderWidth: 14)

    // Keeper star, centred on the front card, matching its slight tilt.
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.saveGState()
    ctx.translateBy(x: cx, y: cy - side * 0.045)
    ctx.rotate(by: 2.5 * .pi / 180)
    let star = NSBezierPath()
    let outer = side * 0.115, inner = outer * 0.42
    for i in 0..<10 {
        let radius = i.isMultiple(of: 2) ? outer : inner
        let a = CGFloat(i) * .pi / 5 + .pi / 2
        let pt = NSPoint(x: cos(a) * radius, y: sin(a) * radius)
        if i == 0 { star.move(to: pt) } else { star.line(to: pt) }
    }
    star.close()
    teal.setFill(); star.fill()
    ctx.restoreGState()

    return true
}

// Compose + write via the shared pipeline. background nil: the foreground
// already paints the full ground, so the squircle mask crops it directly.
let assets = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Assets", isDirectory: true)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

let master = CVERAppIcon.compose(foreground: foreground, sheen: true)
try CVERAppIcon.writePNG(master, to: assets.appendingPathComponent("AppIcon-1024.png"))
try CVERAppIcon.writeICNS(master: master, to: assets.appendingPathComponent("AppIcon.icns"))
print("wrote \(assets.path)/AppIcon-1024.png + AppIcon.icns")

#endif   // os(macOS) — icon generation is a desktop build step
