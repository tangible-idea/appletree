import SwiftUI
import AppleTreeCore

enum Theme {
    static let background = Color(hex: 0xFAF9F6)
    static let sidebar = Color(hex: 0xF1F0EB)
    static let ink = Color(hex: 0x292D28)
    static let secondary = Color(hex: 0x81847B)
    static let line = Color(hex: 0xE8E8E1)
    static let accent = Color(hex: 0xD86B3C)
    static let green = Color(hex: 0x60816B)
    static let tileHexes: [UInt32] = [0xD8754F, 0xEAB970, 0x929F87, 0xA59BB6, 0x88A5AD, 0xC1AA89, 0xADAE9F]
    static let tileColors: [Color] = tileHexes.map { Color(hex: $0) }
    /// Mixes a palette colour toward white; 0 keeps it, 1 is white.
    static func blend(_ hex: UInt32, white amount: Double) -> Color {
        func channel(_ shift: UInt32) -> Double {
            let value = Double((hex >> shift) & 255) / 255
            return value + (1 - value) * amount
        }
        return Color(.sRGB, red: channel(16), green: channel(8), blue: channel(0), opacity: 1)
    }
    static func color(_ index: Int) -> Color { tileColors[index % tileColors.count] }
    static func kindColor(_ kind: FileKind) -> Color {
        switch kind {
        case .folder: accent
        case .video: Color(hex: 0xD8754F)
        case .image: Color(hex: 0x8A9C7E)
        case .audio: Color(hex: 0xA59BB6)
        case .archive: Color(hex: 0xCBA264)
        case .document: Color(hex: 0x88A5AD)
        case .code: Color(hex: 0xA59BB6)
        case .certificate: Color(hex: 0xC4574E)
        case .installer: Color(hex: 0xB98A57)
        case .model: Color(hex: 0x7D8FC0)
        case .database: Color(hex: 0x6F9A94)
        case .design: Color(hex: 0xC27A9E)
        case .font: Color(hex: 0x8C8577)
        case .ebook: Color(hex: 0x9A8466)
        case .virtualMachine: Color(hex: 0x6E8299)
        case .log: Color(hex: 0x9C9C8E)
        case .other: secondary
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 13).padding(.vertical, 9)
            .background(configuration.isPressed ? Theme.line : .white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white).padding(.horizontal, 15).padding(.vertical, 10)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .frame(width: 29, height: 29).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(disabled ? Theme.line : Theme.secondary)
        .disabled(disabled).help(help).accessibilityLabel(help)
    }
}

struct FileIcon: View {
    let node: FileNode
    var size: CGFloat = 32
    var body: some View {
        Image(systemName: node.kind.symbol)
            .font(.system(size: size * 0.43, weight: .medium))
            .foregroundStyle(Theme.kindColor(node.kind))
            .frame(width: size, height: size)
            .background(Theme.kindColor(node.kind).opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SmallLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold)).tracking(1.1).foregroundStyle(Theme.secondary)
    }
}
