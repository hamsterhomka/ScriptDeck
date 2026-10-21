import AppKit

// Рисует иконку приложения: градиентный squircle + символ ▶︎ в «терминальных» скобках.
let outputDirectory = CommandLine.arguments[1]
let sizes: [(Int, String)] = [
    (16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
    (128, "128x128"), (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"),
    (512, "512x512"), (1024, "512x512@2x"),
]

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(size) / 1024
    let inset = 100 * scale
    let rect = NSRect(x: inset, y: inset, width: CGFloat(size) - inset * 2, height: CGFloat(size) - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: 185 * scale, yRadius: 185 * scale)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.16, green: 0.18, blue: 0.27, alpha: 1),
        NSColor(srgbRed: 0.06, green: 0.07, blue: 0.10, alpha: 1),
    ])!
    gradient.draw(in: path, angle: -90)

    let glow = NSGradient(colors: [
        NSColor(srgbRed: 0.35, green: 0.55, blue: 1.0, alpha: 0.45),
        NSColor(srgbRed: 0.35, green: 0.55, blue: 1.0, alpha: 0.0),
    ])!
    glow.draw(in: path, relativeCenterPosition: NSPoint(x: -0.4, y: 0.5))

    let symbolConfig = NSImage.SymbolConfiguration(pointSize: 430 * scale, weight: .bold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(srgbRed: 0.42, green: 0.86, blue: 0.58, alpha: 1)]))
    if let symbol = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)?.withSymbolConfiguration(symbolConfig) {
        let symbolSize = symbol.size
        let origin = NSPoint(x: (CGFloat(size) - symbolSize.width) / 2 + 20 * scale, y: (CGFloat(size) - symbolSize.height) / 2)
        symbol.draw(in: NSRect(origin: origin, size: symbolSize))
    }

    let bracketFont = NSFont.monospacedSystemFont(ofSize: 300 * scale, weight: .heavy)
    let bracketAttributes: [NSAttributedString.Key: Any] = [
        .font: bracketFont,
        .foregroundColor: NSColor.white.withAlphaComponent(0.22),
    ]
    let left = NSAttributedString(string: "{", attributes: bracketAttributes)
    let right = NSAttributedString(string: "}", attributes: bracketAttributes)
    let bracketY = (CGFloat(size) - left.size().height) / 2
    left.draw(at: NSPoint(x: 190 * scale, y: bracketY))
    right.draw(at: NSPoint(x: CGFloat(size) - 190 * scale - right.size().width, y: bracketY))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
for (size, name) in sizes {
    try! render(size: size).write(to: URL(fileURLWithPath: "\(outputDirectory)/icon_\(name).png"))
}
