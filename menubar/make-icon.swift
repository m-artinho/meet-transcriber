// Draws the app icon into an .iconset folder (all sizes macOS needs).
//
//   swiftc -O menubar/make-icon.swift -o /tmp/make-icon && /tmp/make-icon /tmp/AppIcon.iconset
//   iconutil -c icns /tmp/AppIcon.iconset -o menubar/AppIcon.icns
//
// Design: macOS-style rounded square with a red gradient and a white
// "waveform.and.mic" SF Symbol.

import AppKit

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels) / 1024 // design on a 1024 grid

    // Body: 824x824 rounded square centered on the canvas (Apple's icon grid).
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 20 * s
    shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: NSColor(srgbRed: 1.00, green: 0.42, blue: 0.38, alpha: 1),
               ending: NSColor(srgbRed: 0.80, green: 0.12, blue: 0.16, alpha: 1))!.draw(in: path, angle: -90)

    // Symbol, white, centered.
    let config = NSImage.SymbolConfiguration(pointSize: 470 * s, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "waveform.and.mic", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let size = symbol.size
        let rect = NSRect(x: body.midX - size.width / 2, y: body.midY - size.height / 2,
                          width: size.width, height: size.height)
        symbol.draw(in: rect)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)" + (scale == 2 ? "@2x" : "") + ".png"
        let png = drawIcon(pixels: base * scale).representation(using: .png, properties: [:])!
        try! png.write(to: out.appendingPathComponent(name))
    }
}
print("wrote \(out.path)")
