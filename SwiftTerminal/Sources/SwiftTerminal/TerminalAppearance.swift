import AppKit
import SwiftTerm

/// Everything the terminal view needs to render itself, kept as a plain value
/// so SwiftUI can diff it and push live updates into the AppKit view.
struct TerminalAppearance: Equatable, Sendable {
    var fontSize: Double = 13
    var paletteID: String = TerminalPalette.system.id
    var cursorID: String = TerminalCursorPreference.program.rawValue
    var scrollbackLines: Int = 5_000
    var shellPath: String = "/bin/zsh"
    var startDirectory: String = ""

    var palette: TerminalPalette { TerminalPalette.preset(id: paletteID) }
    var cursor: TerminalCursorPreference { TerminalCursorPreference(rawValue: cursorID) ?? .program }
}

/// Curated ANSI palettes. `system` keeps SwiftTerm's own colours so the
/// terminal follows the current macOS appearance.
struct TerminalPalette: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let background: String?
    let foreground: String?
    let ansi: [String]

    var isSystem: Bool { ansi.count != 16 }

    static let system = TerminalPalette(
        id: "system",
        name: "跟随系统",
        background: nil,
        foreground: nil,
        ansi: []
    )

    static let nord = TerminalPalette(
        id: "nord",
        name: "Nord",
        background: "#2E3440",
        foreground: "#D8DEE9",
        ansi: [
            "#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B",
            "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0",
            "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B",
            "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4"
        ]
    )

    static let dracula = TerminalPalette(
        id: "dracula",
        name: "Dracula",
        background: "#282A36",
        foreground: "#F8F8F2",
        ansi: [
            "#21222C", "#FF5555", "#50FA7B", "#F1FA8C",
            "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2",
            "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5",
            "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF"
        ]
    )

    static let solarizedDark = TerminalPalette(
        id: "solarized-dark",
        name: "Solarized Dark",
        background: "#002B36",
        foreground: "#839496",
        ansi: [
            "#073642", "#DC322F", "#859900", "#B58900",
            "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
            "#002B36", "#CB4B16", "#586E75", "#657B83",
            "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"
        ]
    )

    static let solarizedLight = TerminalPalette(
        id: "solarized-light",
        name: "Solarized Light",
        background: "#FDF6E3",
        foreground: "#657B83",
        ansi: [
            "#073642", "#DC322F", "#859900", "#B58900",
            "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
            "#002B36", "#CB4B16", "#586E75", "#657B83",
            "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"
        ]
    )

    static let presets: [TerminalPalette] = [system, nord, dracula, solarizedDark, solarizedLight]

    static func preset(id: String) -> TerminalPalette {
        presets.first { $0.id == id } ?? system
    }
}

enum TerminalCursorPreference: String, CaseIterable, Identifiable {
    case program = "跟随程序"
    case blinkBlock = "闪烁方块"
    case steadyBlock = "常亮方块"
    case blinkBar = "闪烁竖线"
    case steadyBar = "常亮竖线"
    case blinkUnderline = "闪烁下划线"
    case steadyUnderline = "常亮下划线"

    var id: String { rawValue }

    /// `nil` leaves the cursor style to the program running in the terminal.
    var swiftTermStyle: CursorStyle? {
        switch self {
        case .program: return nil
        case .blinkBlock: return .blinkBlock
        case .steadyBlock: return .steadyBlock
        case .blinkBar: return .blinkBar
        case .steadyBar: return .steadyBar
        case .blinkUnderline: return .blinkUnderline
        case .steadyUnderline: return .steadyUnderline
        }
    }
}

@MainActor
enum TerminalAppearanceApplier {
    static func apply(_ appearance: TerminalAppearance, to terminal: LocalProcessTerminalView) {
        let font = NSFont.monospacedSystemFont(ofSize: appearance.fontSize, weight: .regular)
        // SwiftTerm's font setter resizes and soft-resets even for the same
        // font. Ordinary SwiftUI updates must not clear a live prompt's marks.
        if terminal.font != font {
            terminal.font = font
        }

        reassertColors(appearance, to: terminal)

        // Reset explicit overrides to the standard blinking block when users
        // switch back to program-controlled cursor behavior. Applications can
        // then change it normally with DECSCUSR.
        terminal.getTerminal().setCursorStyle(appearance.cursor.swiftTermStyle ?? .blinkBlock)
        let scrollback = max(0, appearance.scrollbackLines)
        terminal.getTerminal().changeScrollback(scrollback == 0 ? nil : scrollback)
    }

    /// Re-assert only the palette (default foreground/background + ANSI 16).
    /// Applications may override the terminal's colors at run time with OSC 10
    /// and OSC 11; without this, one such override permanently turns the
    /// terminal dark even though the app owns the default appearance. Called
    /// on every fresh prompt and when the app becomes active again.
    static func reassertColors(_ appearance: TerminalAppearance, to terminal: LocalProcessTerminalView) {
        // NSColor.textBackgroundColor / .textColor are dynamic: they only
        // resolve to concrete values against NSAppearance.current. Pin it to
        // the view's effective appearance so a system light/dark switch is
        // picked up exactly once, here, instead of whenever the conversion
        // happens to run.
        let previousAppearance = NSAppearance.current
        NSAppearance.current = terminal.effectiveAppearance
        defer { NSAppearance.current = previousAppearance }
        let palette = appearance.palette
        if palette.isSystem {
            terminal.configureNativeColors()
            terminal.installColors(SwiftTerm.Color.terminalAppColors)
        } else {
            if let background = palette.background.flatMap(NSColor.init(hex:)) {
                terminal.nativeBackgroundColor = background
            }
            if let foreground = palette.foreground.flatMap(NSColor.init(hex:)) {
                terminal.nativeForegroundColor = foreground
            }
            let colors = palette.ansi.compactMap(SwiftTerm.Color.init(hex:))
            if colors.count == 16 { terminal.installColors(colors) }
        }
    }
}

enum TerminalHex {
    static func components(_ hex: String) -> (red: UInt16, green: UInt16, blue: UInt16)? {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        return (
            red: UInt16((number >> 16) & 0xFF),
            green: UInt16((number >> 8) & 0xFF),
            blue: UInt16(number & 0xFF)
        )
    }

    static func color(_ hex: String) -> NSColor? {
        guard let components = components(hex) else { return nil }
        return NSColor(
            srgbRed: CGFloat(components.red) / 255,
            green: CGFloat(components.green) / 255,
            blue: CGFloat(components.blue) / 255,
            alpha: 1
        )
    }
}

extension NSColor {
    convenience init?(hex: String) {
        guard let components = TerminalHex.components(hex) else { return nil }
        self.init(
            srgbRed: CGFloat(components.red) / 255,
            green: CGFloat(components.green) / 255,
            blue: CGFloat(components.blue) / 255,
            alpha: 1
        )
    }
}

extension SwiftTerm.Color {
    convenience init?(hex: String) {
        guard let components = TerminalHex.components(hex) else { return nil }
        self.init(red8: components.red, green8: components.green, blue8: components.blue)
    }
}
