import AppKit

enum Palette {
    // Терминал тёмный в любой теме — цвета берём из выбранной палитры в момент отрисовки.
    private static func fromPalette(_ pick: @escaping (PaletteColors) -> UInt32) -> NSColor {
        NSColor(name: nil) { _ in Theme.rgb(pick(DarkPalette.current.colors)) }
    }

    static let background = fromPalette(\.terminal)
    static let foreground = fromPalette(\.text)
    static let dim = fromPalette(\.dim)
    static let accent = fromPalette(\.accent)
    static let error = NSColor(srgbRed: 1.0, green: 0.45, blue: 0.45, alpha: 1)
    static let success = NSColor(srgbRed: 0.45, green: 0.85, blue: 0.55, alpha: 1)

    static func color(hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// Базовые 16 цветов, подобранные под тёмный фон.
    static let ansi: [NSColor] = [
        0x3B3F4A, 0xFF6B6B, 0x6BD68A, 0xF2C66D, 0x6AA8FF, 0xC792EA, 0x5FD7E0, 0xD7DAE0,
        0x6B7280, 0xFF8A8A, 0x8BE9A4, 0xFFD98A, 0x8EC0FF, 0xDDB0FF, 0x89E8EF, 0xFFFFFF,
    ].map(color(hex:))

    static func xterm256(_ index: Int) -> NSColor {
        if index < 16 { return ansi[index] }
        if index < 232 {
            let value = index - 16
            let steps: [CGFloat] = [0, 95, 135, 175, 215, 255]
            return NSColor(srgbRed: steps[value / 36] / 255, green: steps[(value / 6) % 6] / 255,
                           blue: steps[value % 6] / 255, alpha: 1)
        }
        let gray = CGFloat(8 + (index - 232) * 10) / 255
        return NSColor(srgbRed: gray, green: gray, blue: gray, alpha: 1)
    }
}

/// Превращает строки с ANSI escape-последовательностями в NSAttributedString.
/// Состояние (цвет, жирность) переносится между строками, как в настоящем терминале.
final class ANSIRenderer {
    static let fontSize: CGFloat = 12
    static let regularFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    static let boldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)

    private var foreground: NSColor?
    private var background: NSColor?
    private var isBold = false
    private var isDim = false
    private var isItalic = false
    private var isUnderline = false
    private var isInverse = false

    private static let linkRegex = try! NSRegularExpression(pattern: #"https?://[^\s'"<>\)\]]+"#)

    func reset() {
        foreground = nil; background = nil
        isBold = false; isDim = false; isItalic = false; isUnderline = false; isInverse = false
    }

    func render(_ line: String) -> (attributed: NSAttributedString, plain: String) {
        let result = NSMutableAttributedString()
        var plain = ""
        var buffer = ""
        let scalars = Array(line.unicodeScalars)
        var index = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            result.append(NSAttributedString(string: buffer, attributes: currentAttributes()))
            plain += buffer
            buffer = ""
        }

        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\u{1B}", index + 1 < scalars.count {
                let next = scalars[index + 1]
                if next == "[" {
                    // CSI: ESC [ params final
                    var end = index + 2
                    while end < scalars.count, !(0x40...0x7E).contains(scalars[end].value) { end += 1 }
                    guard end < scalars.count else { break }
                    if scalars[end] == "m" {
                        flush()
                        let params = String(String.UnicodeScalarView(scalars[(index + 2)..<end]))
                        applySGR(params)
                    }
                    index = end + 1
                    continue
                }
                if next == "]" {
                    // OSC: ESC ] ... (BEL | ESC \)
                    var end = index + 2
                    while end < scalars.count {
                        if scalars[end] == "\u{07}" { end += 1; break }
                        if scalars[end] == "\u{1B}", end + 1 < scalars.count, scalars[end + 1] == "\\" { end += 2; break }
                        end += 1
                    }
                    index = end
                    continue
                }
                index += 2
                continue
            }
            if scalar.value < 0x20, scalar != "\t" {
                index += 1
                continue
            }
            buffer.unicodeScalars.append(scalar)
            index += 1
        }
        flush()
        addLinks(to: result)
        return (result, plain)
    }

    private func addLinks(to string: NSMutableAttributedString) {
        let text = string.string
        let range = NSRange(text.startIndex..., in: text)
        for match in Self.linkRegex.matches(in: text, range: range) {
            guard let swiftRange = Range(match.range, in: text) else { continue }
            var urlString = String(text[swiftRange])
            while let last = urlString.last, ".,;:".contains(last) { urlString.removeLast() }
            guard let url = URL(string: urlString) else { continue }
            let linkRange = NSRange(location: match.range.location, length: (urlString as NSString).length)
            string.addAttributes([.link: url, .underlineStyle: NSUnderlineStyle.single.rawValue], range: linkRange)
        }
    }

    private func currentAttributes() -> [NSAttributedString.Key: Any] {
        var fg = foreground ?? Palette.foreground
        var bg = background
        if isInverse {
            let swapped = bg ?? Palette.background
            bg = fg
            fg = swapped
        }
        if isDim { fg = fg.withAlphaComponent(0.6) }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: isBold ? Self.boldFont : Self.regularFont,
            .foregroundColor: fg,
        ]
        if let bg { attributes[.backgroundColor] = bg }
        if isUnderline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if isItalic { attributes[.obliqueness] = 0.15 }
        return attributes
    }

    private func applySGR(_ params: String) {
        var codes = params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        if codes.isEmpty { codes = [0] }
        var index = 0
        while index < codes.count {
            let code = codes[index]
            switch code {
            case 0: reset()
            case 1: isBold = true
            case 2: isDim = true
            case 3: isItalic = true
            case 4: isUnderline = true
            case 7: isInverse = true
            case 22: isBold = false; isDim = false
            case 23: isItalic = false
            case 24: isUnderline = false
            case 27: isInverse = false
            case 30...37: foreground = Palette.ansi[code - 30]
            case 90...97: foreground = Palette.ansi[code - 90 + 8]
            case 39: foreground = nil
            case 40...47: background = Palette.ansi[code - 40]
            case 100...107: background = Palette.ansi[code - 100 + 8]
            case 49: background = nil
            case 38, 48:
                let isForeground = code == 38
                if index + 2 < codes.count, codes[index + 1] == 5 {
                    let color = Palette.xterm256(min(max(codes[index + 2], 0), 255))
                    if isForeground { foreground = color } else { background = color }
                    index += 2
                } else if index + 4 < codes.count, codes[index + 1] == 2 {
                    let color = NSColor(srgbRed: CGFloat(codes[index + 2]) / 255, green: CGFloat(codes[index + 3]) / 255,
                                        blue: CGFloat(codes[index + 4]) / 255, alpha: 1)
                    if isForeground { foreground = color } else { background = color }
                    index += 4
                }
            default: break
            }
            index += 1
        }
    }
}
