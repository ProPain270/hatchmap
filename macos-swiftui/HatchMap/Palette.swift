import SwiftUI

enum Palette {
    static func color(_ s: String) -> Color {
        switch s {
        case "ok":   return .green
        case "warn": return .orange
        case "crit": return .red
        case "host": return .teal
        case "lxc":  return .green
        case "vm":   return .purple
        case "docker": return .orange
        case "guard": return .cyan
        case "store": return .yellow
        case "net":  return .blue
        default:     return .gray
        }
    }
    static func icon(_ t: String) -> String {
        switch t {
        case "host":   return "server.rack"
        case "lxc":    return "shippingbox"
        case "vm":     return "desktopcomputer"
        case "docker": return "cube.box"
        case "guard":  return "shield.checkered"
        case "store":  return "internaldrive"
        case "net":    return "network"
        default:       return "circle"
        }
    }
    /// Maps the contract's semantic group icon names to SF Symbols.
    static func groupIcon(_ s: String) -> String {
        switch s {
        case "movie":  return "film"
        case "magnet": return "magnet"
        case "lock":   return "lock"
        case "chart":  return "chart.bar"
        case "gear":   return "gear"
        case "disk":   return "internaldrive"
        case "shield": return "shield"
        default:       return "square.grid.2x2"
        }
    }
    static func expo(_ e: String) -> String {
        switch e {
        case "funnel": return "Public · Funnel"
        case "tail":   return "Tailnet only"
        case "vpn":    return "VPN egress"
        case "local":  return "LAN only"
        default:       return e
        }
    }
    static func expoColor(_ e: String) -> Color {
        switch e {
        case "funnel": return .blue
        case "tail":   return .purple
        case "vpn":    return .red
        case "local":  return .gray
        default:       return .gray
        }
    }
    static func storageColor(_ pct: Int) -> Color {
        if pct >= 90 { return .red }
        if pct >= 70 { return .orange }
        return .green
    }
}

/// Design tokens. Opacity-based so they adapt to light and dark mode.
enum Theme {
    static let card      = Color.primary.opacity(0.045)
    static let selected  = Color.accentColor.opacity(0.16)
    static let border    = Color.primary.opacity(0.10)
    static let radius: CGFloat = 14
}
