import Foundation
import UserNotifications

/// Local macOS notifications. Phone push is deliberately server-side (hatch-notify → ntfy) so it
/// survives this Mac sleeping; this class only mirrors state changes to Notification Center.
final class Notifier {
    static let shared = Notifier()
    private var authorized = false
    private var asked = false
    private var recent: [String: Date] = [:]

    /// UNUserNotificationCenter requires a real app bundle; a bare binary run from a shell would
    /// crash on `.current()`, so guard on the bundle identifier.
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func requestAuthorization() {
        guard available, !asked else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] ok, _ in
            self?.authorized = ok
        }
    }

    enum Kind { case nodeDown, nodeUp, disk, sitrep, threat, newDevice, action, other }

    private func allowed(_ k: Kind) -> Bool {
        let o = Options.shared
        switch k {
        case .nodeDown: return o.nNodeDown
        case .nodeUp: return o.nNodeUp
        case .disk: return o.nDisk
        case .sitrep: return o.nSitrep
        case .threat: return o.nThreat
        case .newDevice: return o.nNewDevice
        case .action: return o.nAction
        case .other: return true
        }
    }

    func post(title: String, body: String, id: String? = nil, kind: Kind = .other) {
        guard available, Options.shared.localNotifications, allowed(kind) else { return }
        let key = id ?? title + body
        if let last = recent[key], Date().timeIntervalSince(last) < 300 { return }   // same event, 5-minute cooldown
        recent[key] = Date()
        if recent.count > 500 { recent = recent.filter { Date().timeIntervalSince($0.value) < 3600 } }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { _ in }
    }

    /// Topology transitions worth interrupting for: a node going down or coming back, a disk
    /// crossing 90 %, a SITREP card turning warn/crit.
    func stateChange(_ c: ChangeItem) {
        switch c.kind {
        case "state":
            if c.to == "down" { post(title: "\(c.name) is down", body: "Was \(c.from). Open HatchMap for details.", id: "down-\(c.key)", kind: .nodeDown) }
            else if c.from == "down" && c.to == "up" { post(title: "\(c.name) is back up", body: "Recovered after being down.", id: "up-\(c.key)", kind: .nodeUp) }
            else if c.to == "warn" { post(title: "\(c.name) degraded", body: "State changed \(c.from) → \(c.to).", id: "warn-\(c.key)", kind: .nodeUp) }
        case "storage":
            if c.isBad { post(title: "\(c.name) storage \(c.to)", body: "Crossed a fill threshold (was \(c.from)).", id: "disk-\(c.key)", kind: .disk) }
        case "sitrep":
            if c.to == "crit" || c.to == "warn" { post(title: "\(c.name): \(c.to)", body: "SITREP changed \(c.from) → \(c.to).", id: "sit-\(c.key)", kind: .sitrep) }
        default: break
        }
    }
}
