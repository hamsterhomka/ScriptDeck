import AppKit
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Как в системе"
        case .light: "Светлая"
        case .dark: "Тёмная"
        }
    }

    var icon: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon.stars"
        }
    }

    static let storageKey = "appearance"

    static var current: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// Набор цветов тёмной темы (и терминала — он тёмный всегда).
struct PaletteColors {
    var chrome: UInt32          // панель вкладок
    var selectedTab: UInt32
    var projects: UInt32        // колонка проектов
    var scripts: UInt32         // колонка скриптов
    var header: UInt32          // шапка над логом
    var terminal: UInt32        // фон лога
    var text: UInt32            // основной текст лога
    var dim: UInt32
    var accent: UInt32
    var border: UInt32
}

enum DarkPalette: String, CaseIterable, Identifiable {
    case claude, cursor, webstorm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: "Claude"
        case .cursor: "Cursor"
        case .webstorm: "WebStorm"
        }
    }

    var colors: PaletteColors {
        switch self {
        case .claude:
            // Тёплый графит и терракотовый акцент.
            PaletteColors(chrome: 0x1A1918, selectedTab: 0x30302E, projects: 0x1F1E1D, scripts: 0x232321,
                          header: 0x262624, terminal: 0x262624, text: 0xE5E3DA, dim: 0x9A988E,
                          accent: 0xD97757, border: 0x3A3936)
        case .cursor:
            // Почти чёрный нейтральный, панели различаются едва заметно.
            PaletteColors(chrome: 0x141414, selectedTab: 0x232323, projects: 0x141414, scripts: 0x181818,
                          header: 0x181818, terminal: 0x181818, text: 0xD6D6DD, dim: 0x8B8B93,
                          accent: 0x4C9DF8, border: 0x2A2A2A)
        case .webstorm:
            // JetBrains New UI Dark.
            PaletteColors(chrome: 0x2B2D30, selectedTab: 0x393B40, projects: 0x2B2D30, scripts: 0x2B2D30,
                          header: 0x1E1F22, terminal: 0x1E1F22, text: 0xDFE1E5, dim: 0x8C8F96,
                          accent: 0x3574F0, border: 0x1E1F22)
        }
    }

    static let storageKey = "darkPalette"

    static var current: DarkPalette {
        DarkPalette(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .webstorm
    }
}

/// Цвета интерфейса. Тёмные значения берутся из выбранной палитры в момент отрисовки.
enum Theme {
    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func dynamicNS(light: NSColor, dark: @escaping (PaletteColors) -> NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            isDark(appearance) ? dark(DarkPalette.current.colors) : light
        }
    }

    private static func dynamic(light: NSColor, dark: @escaping (PaletteColors) -> NSColor) -> Color {
        Color(nsColor: dynamicNS(light: light, dark: dark))
    }

    static let chrome = dynamic(light: rgb(0xE9E9EC)) { rgb($0.chrome) }
    static let selectedTab = dynamic(light: .white) { rgb($0.selectedTab) }
    static let selectedTabBorder = dynamic(light: rgb(0x000000, alpha: 0.08)) { rgb($0.border) }
    static let header = dynamic(light: rgb(0xF7F7F9)) { rgb($0.header) }
    static let projectsColumn = dynamic(light: rgb(0xEDEDF1)) { rgb($0.projects) }
    static let scriptsColumn = dynamic(light: rgb(0xF5F5F8)) { rgb($0.scripts) }
    static let detailBackground = dynamic(light: .white) { rgb($0.terminal) }
    static let separator = dynamic(light: rgb(0x000000, alpha: 0.1)) { rgb($0.border) }
    static let fieldBackground = dynamic(light: rgb(0x000000, alpha: 0.06)) { _ in rgb(0xFFFFFF, alpha: 0.06) }
    static let accent = dynamic(light: rgb(0x0A84FF)) { rgb($0.accent) }
}
