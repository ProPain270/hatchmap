import SwiftUI
import Foundation
import AppKit
import Darwin
import Network
import UserNotifications

// MARK: - Design tokens — adaptive. NetSight shipped dark-only; inside HatchMap's system-themed
// shell the same roles resolve per appearance so the Network views read as one app in light and dark.

func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { app in
        app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    })
}
func dynRGB(_ l: (Double, Double, Double), _ d: (Double, Double, Double)) -> Color {
    dyn(NSColor(red: l.0, green: l.1, blue: l.2, alpha: 1), NSColor(red: d.0, green: d.1, blue: d.2, alpha: 1))
}

enum Pal {
    static let bg     = Color.clear                              // the window's own background shows through
    static let rail   = Color.primary.opacity(0.03)              // inspector / side panes
    static let panel  = Theme.card                               // cards — same token as the map views
    static let panel2 = Color.primary.opacity(0.08)              // raised cards, inputs
    static let stroke = Theme.border
    static let ink    = Color.primary
    static let ink2   = Color.secondary
    static let ink3   = Color.secondary.opacity(0.78)
    static let badgeInk = dyn(.white, .black)                    // text on a saturated badge
    static let live   = dynRGB((0.09, 0.55, 0.32), (0.28, 0.87, 0.56))   // capture-signal green
    static let info   = dynRGB((0.00, 0.44, 0.86), (0.44, 0.71, 1.00))
    static let warn   = dynRGB((0.78, 0.48, 0.03), (0.96, 0.68, 0.26))
    static let bad    = dynRGB((0.80, 0.16, 0.16), (0.97, 0.38, 0.38))
    static let radius: CGFloat = 8
}

func dataFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }

struct CardBG: ViewModifier {
    var raised = false
    func body(content: Content) -> some View {
        content.background(raised ? Pal.panel2 : Pal.panel).clipShape(RoundedRectangle(cornerRadius: Pal.radius))
            .overlay(RoundedRectangle(cornerRadius: Pal.radius).stroke(Pal.stroke, lineWidth: 1))
    }
}
extension View { func card(raised: Bool = false) -> some View { modifier(CardBG(raised: raised)) } }

func sectionLabel(_ t: String) -> some View {
    Text(t.uppercased()).font(dataFont(9.5, .semibold)).foregroundStyle(Pal.ink3).kerning(1.2)
}

// MARK: - UI helpers

let BG = Pal.bg

func deviceColor(_ ip: String) -> Color {
    if ip.isEmpty { return Color.gray }
    var h: UInt64 = 5381
    for b in ip.utf8 { h = ((h << 5) &+ h) &+ UInt64(b) }
    return Color(hue: Double(h % 360) / 360.0, saturation: 0.55, brightness: 0.9)
}

func directionIcon(_ d: String) -> (String, Color) {
    switch d {
    case "out": return ("arrow.up.right", Color(red: 0.78, green: 0.55, blue: 0.95))
    case "in": return ("arrow.down.left", Color(red: 1.0, green: 0.6, blue: 0.4))
    case "local": return ("arrow.left.arrow.right", Color(red: 0.45, green: 0.66, blue: 1.0))
    default: return ("eye", Color.gray)
    }
}

func categoryColor(_ c: String) -> Color {
    switch c {
    case "Ad / tracker": return Color(red: 0.90, green: 0.35, blue: 0.35)
    case "Streaming": return Color(red: 0.93, green: 0.70, blue: 0.30)
    case "Music": return Color(red: 0.66, green: 0.55, blue: 0.95)
    case "Social": return Color(red: 0.40, green: 0.65, blue: 0.95)
    case "IoT telemetry": return Color(red: 0.80, green: 0.55, blue: 0.30)
    case "Local": return Color(red: 0.35, green: 0.80, blue: 0.62)
    default: return Color(red: 0.55, green: 0.75, blue: 0.95)
    }
}

// MARK: - Per-flow explanation

func encryptionOf(_ port: Int, _ proto: String) -> String {
    switch port {
    case 443, 993, 995, 465, 8443, 22, 3478, 5223: return "Encrypted"
    case 80, 8080: return "Not encrypted (HTTP)"
    case 53, 5353: return "Not encrypted (DNS)"
    case 21, 23: return "Not encrypted (legacy)"
    default: return proto == "UDP" ? "Unknown (UDP)" : "Unknown"
    }
}

func serviceName(_ port: Int) -> String {
    if let n = WELL_KNOWN[port] { return n }
    switch port { case 8080: return "HTTP"; case 8443: return "HTTPS"; default: return "port \(port)" }
}

func bestHost(_ e: TrafficEvent) -> String {
    if e.isPrivate { return e.host }
    return DNSMap.shared.domain(e.remoteIP) ?? e.host
}

func shortOrg(_ e: TrafficEvent) -> String {
    let h = bestHost(e)
    if h.contains(".") && h.contains(where: { $0.isLetter }) { return h }
    if !e.org.isEmpty { return e.org }
    return h.isEmpty ? e.dst : h
}

// MARK: - Service + activity resolution (computed live, so late-arriving DNS still lands)

func serviceOf(_ e: TrafficEvent) -> ServiceHit? {
    if e.isPrivate { return nil }
    return ServiceDB.shared.match(host: bestHost(e), org: e.org, port: e.servicePort)
}

func appInfoOf(_ e: TrafficEvent) -> AppInfo? {
    if e.app.isEmpty { return nil }
    return AppDB.shared.info(e.app)
}

func appDisplayOf(_ e: TrafficEvent) -> String {
    if e.app.isEmpty { return "" }
    return AppDB.shared.info(e.app)?.display ?? e.app
}

func volumeOf(_ e: TrafficEvent) -> (total: Int, out: Int, inn: Int, packets: Int) {
    if let s = FlowStats.shared.get(e.flowKey) { return (s.bytes, s.outBytes, s.inBytes, s.packets) }
    return (e.bytes, 0, 0, 1)
}

struct Activity { let headline: String; let detail: String; let icon: String; let conf: String }

func activityOf(_ e: TrafficEvent) -> Activity {
    let port = e.servicePort
    let out = e.direction == "out"
    let vol = volumeOf(e).total
    let volStr = vol > 0 ? " · \(fmtBytes(vol)) so far" : ""
    if e.isPrivate {
        let peer = resolveDevice(e.dst).name
        return Activity(headline: "Local network traffic", detail: "Talking to \(peer) (\(e.dst)) on your own network over \(serviceName(port))\(volStr).", icon: "house", conf: "confirmed")
    }
    // Strong port/protocol signals first (these are certain regardless of domain)
    switch port {
    case 993, 995, 143: return Activity(headline: "Checking email", detail: "Syncing a mailbox over \(serviceName(port))\(volStr).", icon: "envelope", conf: "confirmed")
    case 587, 465, 25: return Activity(headline: "Sending email", detail: "Submitting outgoing mail over \(serviceName(port)).", icon: "paperplane", conf: "confirmed")
    case 3478, 3479, 5349, 5350: return Activity(headline: "Voice or video call", detail: "Real-time call media (STUN/TURN)\(volStr).", icon: "phone", conf: "likely")
    case 5223: return Activity(headline: "Push notifications", detail: "Persistent Apple push channel — how notifications & iMessages arrive.", icon: "bell.badge", conf: "confirmed")
    case 123: return Activity(headline: "Clock sync", detail: "Setting the time from an internet clock (NTP).", icon: "clock", conf: "confirmed")
    case 53, 5353: return Activity(headline: "Domain-name lookup", detail: "Looking up an address (DNS).", icon: "magnifyingglass", conf: "confirmed")
    case 32400: return Activity(headline: "Plex media streaming", detail: "Plex media-server traffic\(volStr).", icon: "play.rectangle", conf: "confirmed")
    case 445, 139: return Activity(headline: "File sharing", detail: "Windows/SMB file sharing\(volStr).", icon: "folder", conf: "confirmed")
    case 22: return Activity(headline: "Secure shell (SSH)", detail: "Encrypted remote login / administration.", icon: "terminal", conf: "confirmed")
    case 3389: return Activity(headline: "Remote desktop", detail: "Remote Desktop (RDP) session.", icon: "display", conf: "confirmed")
    default: break
    }
    if let s = serviceOf(e) {
        let verb: String
        switch s.category {
        case "Streaming": verb = out ? "Streaming from" : "Streaming"
        case "Music": verb = "Streaming music from"
        case "Ad / tracker": verb = "Contacting"
        case "Social": verb = "Using"
        case "IoT telemetry": verb = "Checking in with"
        default: verb = "Connecting to"
        }
        return Activity(headline: s.purpose, detail: "\(verb) \(s.name)\(volStr).", icon: s.icon, conf: s.confidence)
    }
    if port == 80 { return Activity(headline: "Unencrypted web", detail: "Plain HTTP to \(shortOrg(e))\(volStr).", icon: "globe", conf: "confirmed") }
    if e.direction == "in" { return Activity(headline: "Incoming connection", detail: "\(serviceName(port)) from \(shortOrg(e))\(volStr).", icon: "arrow.down.left", conf: "likely") }
    return Activity(headline: "Encrypted app / web traffic", detail: "\(serviceName(port)) with \(shortOrg(e))\(volStr).", icon: "lock", conf: "likely")
}

func confLabel(_ c: String) -> String {
    switch c {
    case "confirmed": return "Confirmed"
    case "likely": return "Likely"
    case "generic": return "Can't confirm (shared host)"
    default: return c
    }
}

// How we know what this is — ground truth for the Mac, inference for other devices.
func attributionOf(_ e: TrafficEvent) -> (text: String, level: String) {
    if !e.app.isEmpty {
        let d = appDisplayOf(e)
        let extra = (d != e.app) ? " (\(e.app))" : ""
        return ("Confirmed on this Mac — this traffic is owned by the process \(d)\(extra).", "confirmed")
    }
    if let s = serviceOf(e) {
        let bh = bestHost(e)
        let ev = (bh.contains(".") && bh.contains(where: { $0.isLetter })) ? "the domain \(bh)" : (e.org.isEmpty ? "its network address" : "the \(e.org) network")
        if s.confidence == "generic" {
            return ("Inferred: \(s.name) is a shared CDN/host — the specific app can't be confirmed from the network alone.", "generic")
        }
        return ("Inferred from \(ev) — \(confLabel(s.confidence).lowercased()). Other devices don't expose their app list, so this is read from the network fingerprint.", s.confidence)
    }
    return ("", "")
}

func flowHeadline(_ e: TrafficEvent) -> String {
    let svc = serviceName(e.servicePort)
    let enc = encryptionOf(e.servicePort, e.proto)
    if e.isPrivate { return "Local network traffic (\(svc))" }
    switch e.direction {
    case "out": return enc == "Encrypted" ? "Encrypted connection to \(shortOrg(e))" : "\(svc) to \(shortOrg(e))"
    case "in": return "Incoming \(svc) from \(shortOrg(e))"
    default: return "\(svc) traffic with \(shortOrg(e))"
    }
}

func categoryNarrative(_ cat: String) -> String {
    switch cat {
    case "Streaming": return "The pattern looks like video or audio streaming."
    case "Music": return "The pattern looks like music streaming."
    case "Social": return "This is social-media traffic."
    case "Ad / tracker": return "This is an advertising or tracking service, usually loaded in the background by apps and websites."
    case "Cloud / CDN": return "This is cloud or content-delivery infrastructure — app data, downloads, and website assets ride on it."
    case "IoT telemetry": return "This looks like a smart-home or IoT device checking in with its maker."
    case "DNS / system": return "This is a name lookup — how your device finds the address of a service."
    case "Apple / system": return "This is Apple system or iCloud traffic."
    default: return "This is general web or app traffic."
    }
}

struct Explanation {
    let headline: String
    let narrative: String
    let facts: [(String, String)]
    let assessment: String
    let level: String
    let activity: String
    let activityDetail: String
    let activityIcon: String
    let attribution: String
    let attributionLevel: String
}

func explain(_ e: TrafficEvent) -> Explanation {
    let svc = serviceName(e.servicePort)
    let enc = encryptionOf(e.servicePort, e.proto)
    let host = bestHost(e)
    let act = activityOf(e)
    let who = e.device.isEmpty ? "A device on your network" : e.device
    let appPhrase = e.app.isEmpty ? "" : " (via \(appDisplayOf(e)))"

    var s: [String] = []
    if e.isPrivate {
        s.append("\(who)\(appPhrase) is talking to another device on your own network (\(e.dst)) over \(svc). This traffic never leaves your home network.")
    } else {
        let orgPhrase = e.org.isEmpty ? "an external server (\(host))" : "servers run by \(e.org)"
        let loc = e.country.isEmpty ? "" : ", located in \(e.country)"
        if e.direction == "in" {
            s.append("A host on the internet\(e.org.isEmpty ? "" : " (\(e.org))")\(loc) connected in to your device using \(svc) (\(e.proto) port \(e.servicePort)).")
        } else {
            s.append("\(who)\(appPhrase) opened an outbound connection to \(orgPhrase)\(loc), using \(svc) (\(e.proto) port \(e.servicePort)).")
        }
        if enc == "Encrypted" { s.append("The connection is encrypted, so its contents are private in transit.") }
        else if enc.contains("DNS") { s.append("This is a domain-name lookup.") }
        else if enc.hasPrefix("Not encrypted") { s.append("It is not encrypted, so the contents could be readable in transit.") }
        s.append(categoryNarrative(e.category))
    }

    var f: [(String, String)] = []
    let dirText: String
    switch e.direction {
    case "out": dirText = "Outbound — your device started it"
    case "in": dirText = "Inbound — started from the internet"
    case "local": dirText = "Local — device to device on your network"
    default: dirText = "Observed — between two other parties"
    }
    f.append(("Activity", act.headline))
    f.append(("Direction", dirText))
    let dm = resolveDevice(e.deviceIP)
    f.append(("Your device", e.device.isEmpty ? "—" : e.device))
    let dcl = deviceClass(e.deviceIP)
    if !e.deviceIP.isEmpty && dcl.klass != "Unknown" {
        f.append(("Device class", (dcl.os == "—" || dcl.os.isEmpty) ? dcl.klass : "\(dcl.klass) · \(dcl.os)"))
    }
    if !e.deviceIP.isEmpty && !dm.isMe && dm.type != "Unknown device" { f.append(("Device type", dm.type)) }
    if !dm.isMe && !dm.vendor.isEmpty { f.append(("Made by", dm.vendor)) }
    if let ai = appInfoOf(e) {
        f.append(("Application", ai.display))
        if ai.display != ai.process { f.append(("Process", ai.process)) }
        if !ai.bundleID.isEmpty { f.append(("Bundle ID", ai.bundleID)) }
        if !ai.signature.isEmpty { f.append(("Signature", ai.signature)) }
        f.append(("App kind", ai.role.capitalized))
    } else if !e.app.isEmpty {
        f.append(("Application", e.app))
    }
    if e.isPrivate {
        let peer = resolveDevice(e.dst)
        f.append(("Local peer", peer.name))
        if !peer.isMe && peer.type != "Unknown device" { f.append(("Peer type", peer.type)) }
    } else {
        f.append(("Destination", host.isEmpty ? e.dst : host))
        if let sv = serviceOf(e) {
            f.append(("Service / app", sv.name))
            if !sv.purpose.isEmpty { f.append(("Purpose", sv.purpose)) }
            f.append(("Identification", confLabel(sv.confidence)))
        }
    }
    if !e.org.isEmpty { f.append(("Organisation", e.org)) }
    if !e.country.isEmpty { f.append(("Location", e.country)) }
    f.append(("Protocol", "\(svc)  ·  \(e.proto) port \(e.servicePort)"))
    f.append(("Encryption", enc))
    f.append(("Category", e.category))
    let vol = volumeOf(e)
    if vol.total > 0 {
        var dv = fmtBytes(vol.total)
        if vol.out > 0 || vol.inn > 0 { dv += "  (↑ \(fmtBytes(vol.out)) · ↓ \(fmtBytes(vol.inn)))" }
        dv += "  ·  \(vol.packets) pkts"
        f.append(("Data seen", dv))
    }
    f.append(("Flow", "\(e.src):\(e.sport) → \(e.dst):\(e.dport)"))

    let assessment: String
    let level: String
    if e.threat.hasPrefix("confirmed") {
        assessment = "Confirmed malicious — matches a trusted threat feed (\(e.threat.replacingOccurrences(of: "confirmed:", with: ""))). Investigate and consider blocking."
        level = "bad"
    } else if e.threat.hasPrefix("suspicious") {
        assessment = "Worth a review — \(e.threat.replacingOccurrences(of: "suspicious:", with: "")). Unusual, but not proven malicious."
        level = "review"
    } else if e.isPrivate {
        assessment = "Normal local traffic — stays on your network."
        level = "local"
    } else if enc == "Encrypted" {
        assessment = "Looks normal — an encrypted connection to a recognised destination."
        level = "ok"
    } else if enc.contains("DNS") {
        assessment = "Normal — a routine name lookup."
        level = "ok"
    } else {
        assessment = "Probably fine, but unencrypted — okay for public content, avoid anything sensitive."
        level = "review"
    }
    let attr = attributionOf(e)
    return Explanation(headline: flowHeadline(e), narrative: s.joined(separator: " "), facts: f, assessment: assessment, level: level,
                       activity: act.headline, activityDetail: act.detail, activityIcon: act.icon,
                       attribution: attr.text, attributionLevel: attr.level)
}

func levelColor(_ l: String) -> Color {
    switch l {
    case "bad": return Color(red: 0.95, green: 0.35, blue: 0.35)
    case "review": return Color(red: 0.95, green: 0.72, blue: 0.30)
    case "local": return Color(red: 0.40, green: 0.80, blue: 0.62)
    default: return Color(red: 0.45, green: 0.80, blue: 0.55)
    }
}

func attrColor(_ l: String) -> Color {
    switch l {
    case "confirmed": return Color(red: 0.45, green: 0.80, blue: 0.55)
    case "generic": return Pal.ink3
    default: return Color(red: 0.62, green: 0.70, blue: 0.95)
    }
}

func attrIcon(_ l: String) -> String {
    switch l {
    case "confirmed": return "checkmark.seal.fill"
    case "generic": return "questionmark.circle"
    default: return "magnifyingglass"
    }
}

func rowSub(_ e: TrafficEvent) -> String {
    if e.isPrivate {
        let t = e.device.isEmpty ? e.dst : "\(e.device) · \(e.dst)"
        return "\(t) · \(serviceName(e.servicePort))"
    }
    var parts: [String] = []
    let app = appDisplayOf(e)
    let svc = serviceOf(e)
    if !app.isEmpty, let s = svc { parts.append("\(app) → \(s.name)") }
    else if !app.isEmpty { parts.append(app) }
    else if let s = svc { parts.append(s.name) }
    else { let bh = bestHost(e); parts.append(bh.isEmpty ? e.dst : bh) }
    parts.append(activityOf(e).headline)
    let vol = volumeOf(e).total
    if vol > 0 { parts.append(fmtBytes(vol)) }
    if !e.country.isEmpty { parts.append(e.country) }
    return parts.joined(separator: " · ")
}
