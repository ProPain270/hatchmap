import AppKit
import Foundation
import SwiftUI

// MARK: - Options — every tunable in one place, persisted in UserDefaults
//
// Views read `options.x` and bind with `options.bind(\.x)`. Engines read `Options.shared.x`
// at the moment they need it, so a change takes effect on the next poll / packet / render.

@propertyWrapper
struct Pref<T> {
    let key: String
    let def: T
    init(_ key: String, _ def: T) { self.key = key; self.def = def }
    var wrappedValue: T {
        get { UserDefaults.standard.object(forKey: key) as? T ?? def }
        nonmutating set {
            Options.shared.objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: key)
        }
    }
}

final class Options: ObservableObject {
    static let shared = Options()

    // Polling & freshness
    @Pref("poll.topology", 30.0)     var topologyPoll: Double        // seconds
    @Pref("poll.actions", 60.0)      var actionsPoll: Double
    @Pref("poll.staleAfter", 90.0)   var staleAfter: Double
    @Pref("captureAtLaunch", true)   var captureAtLaunch: Bool
    @Pref("localNotifications", true) var localNotifications: Bool

    // Overview
    @Pref("ov.attention", true)      var ovAttention: Bool
    @Pref("ov.delta", true)          var ovDelta: Bool
    @Pref("ov.sitrep", true)         var ovSitrep: Bool
    @Pref("ov.storage", true)        var ovStorage: Bool
    @Pref("ov.network", true)        var ovNetwork: Bool
    @Pref("ov.changes", true)        var ovChanges: Bool
    @Pref("ov.diskWarn", 90)         var diskWarn: Int
    @Pref("ov.diskCrit", 95)         var diskCrit: Int
    @Pref("ov.attnNetwork", true)    var attnNetwork: Bool
    @Pref("ov.attnStale", true)      var attnStale: Bool
    @Pref("ov.attnQuiet", true)      var attnQuiet: Bool
    @Pref("ov.runwayDays", 7)        var runwayDays: Int
    @Pref("ov.deltaGapMin", 20)      var deltaGapMin: Int
    @Pref("ov.changesHours", 24)     var changesHours: Int

    // Homelab tiers
    @Pref("tier.compact", false)     var tierCompact: Bool
    @Pref("tier.sort", "generator")  var tierSort: String            // generator | name | state
    @Pref("tier.problemsOnly", false) var tierProblemsOnly: Bool

    // Network · Feed
    @Pref("feed.groupByCategory", false) var feedGrouped: Bool
    @Pref("feed.hideLocal", false)   var feedHideLocal: Bool
    @Pref("feed.hideDNS", false)     var feedHideDNS: Bool
    @Pref("feed.minBytes", 0)        var feedMinBytes: Int
    @Pref("feed.liveCap", 400)       var feedLiveCap: Int
    // Network · Sites / Devices / Apps / History
    @Pref("sites.scope", 0)          var sitesScope: Int             // 0 today · 1 yesterday · 2 7d · 3 30d
    @Pref("sites.hideCats", "")      var sitesHiddenCats: String     // "|"-separated categories
    @Pref("dev.sort", "flows")       var devSort: String             // flows | name | firstSeen
    @Pref("dev.hideUnidentified", false) var devHideUnidentified: Bool
    @Pref("dev.newOnly", false)      var devNewOnly: Bool
    @Pref("apps.sort", "bytes")      var appsSort: String            // bytes | flows | name
    @Pref("apps.hideSystem", false)  var appsHideSystem: Bool
    @Pref("apps.trackersOnly", false) var appsTrackersOnly: Bool
    @Pref("hist.windowMin", 30)      var histWindowMin: Int
    @Pref("hist.topN", 15)           var histTopN: Int
    // Network · Alerts
    @Pref("alerts.showConfirmed", true) var alertsShowConfirmed: Bool
    @Pref("alerts.showReview", true) var alertsShowReview: Bool
    @Pref("alerts.showAnomalies", true) var alertsShowAnomalies: Bool
    @Pref("alerts.mutePlaintext", false) var mutePlaintext: Bool
    @Pref("alerts.muteUnusualPort", false) var muteUnusualPort: Bool
    @Pref("alerts.muteNewDevice", false) var muteNewDevice: Bool
    @Pref("alerts.muteLargeUpload", false) var muteLargeUpload: Bool
    // Network · Capture
    @Pref("cap.interface", "auto")   var capInterface: String
    @Pref("cap.dns", true)           var capDNS: Bool
    @Pref("cap.mdns", true)          var capMDNS: Bool
    @Pref("cap.sni", true)           var capSNI: Bool
    @Pref("cap.dhcp", true)          var capDHCP: Bool
    @Pref("cap.feeds", true)         var capFeeds: Bool
    @Pref("cap.baselineSec", 25)     var capBaselineSec: Int
    @Pref("cap.retentionDays", 30)   var capRetentionDays: Int
    // Network · Scan
    @Pref("scan.extended", false)    var scanExtended: Bool
    @Pref("scan.timeoutMs", 1000)    var scanTimeoutMs: Int
    @Pref("scan.concurrency", 16)    var scanConcurrency: Int

    // Control · Actions
    @Pref("act.showHosts", true)     var actShowHosts: Bool
    @Pref("act.showScripts", true)   var actShowScripts: Bool
    @Pref("act.showContainers", true) var actShowContainers: Bool
    @Pref("act.showProxmox", true)   var actShowProxmox: Bool
    @Pref("act.confirmSafe", true)   var actConfirmSafe: Bool        // destructive always confirms
    @Pref("act.sshUser", "root")     var actSSHUser: String

    // Local (macOS) notification rules
    @Pref("n.nodeDown", true)        var nNodeDown: Bool
    @Pref("n.nodeUp", true)          var nNodeUp: Bool
    @Pref("n.disk", true)            var nDisk: Bool
    @Pref("n.sitrep", true)          var nSitrep: Bool
    @Pref("n.threat", true)          var nThreat: Bool
    @Pref("n.newDevice", true)       var nNewDevice: Bool
    @Pref("n.action", true)          var nAction: Bool

    // Export
    @Pref("exp.range", "all")        var expRange: String            // all | 24h | 7d
    @Pref("exp.hiddenCols", "")      var expHiddenCols: String       // "dataset:col|dataset:col"

    func bind<T>(_ kp: ReferenceWritableKeyPath<Options, T>) -> Binding<T> {
        Binding(get: { self[keyPath: kp] }, set: { self[keyPath: kp] = $0 })
    }

    var sitesHiddenSet: Set<String> { Set(sitesHiddenCats.split(separator: "|").map(String.init)) }
    func toggleSitesCategory(_ c: String) {
        var s = sitesHiddenSet
        if s.contains(c) { s.remove(c) } else { s.insert(c) }
        sitesHiddenCats = s.sorted().joined(separator: "|")
    }
    var hiddenColumns: Set<String> { Set(expHiddenCols.split(separator: "|").map(String.init)) }
    func toggleColumn(_ dataset: String, _ col: String) {
        var s = hiddenColumns
        let key = dataset + ":" + col
        if s.contains(key) { s.remove(key) } else { s.insert(key) }
        expHiddenCols = s.sorted().joined(separator: "|")
    }
    func isColumnHidden(_ dataset: String, _ col: String) -> Bool { hiddenColumns.contains(dataset + ":" + col) }

    /// Reset every option in a group back to its default.
    func reset(prefix: String) {
        let d = UserDefaults.standard
        for k in d.dictionaryRepresentation().keys where k.hasPrefix(prefix) { d.removeObject(forKey: k) }
        objectWillChange.send()
    }
}

// MARK: - Reusable controls

struct OptionRow<Content: View>: View {
    let label: String
    var help: String = ""
    let content: Content
    init(_ label: String, help: String = "", @ViewBuilder content: () -> Content) { self.label = label; self.help = help; self.content = content() }
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.callout)
                if !help.isEmpty { Text(help).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            content
        }
        .padding(.vertical, 3)
    }
}

struct OptionToggle: View {
    let label: String
    var help: String = ""
    let binding: Binding<Bool>
    var body: some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.callout)
                if !help.isEmpty { Text(help).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.vertical, 2)
    }
}

struct OptionStepper: View {
    let label: String
    var help: String = ""
    let binding: Binding<Int>
    let range: ClosedRange<Int>
    var step: Int = 1
    var unit: String = ""
    var body: some View {
        OptionRow(label, help: help) {
            HStack(spacing: 6) {
                Text("\(binding.wrappedValue)\(unit)").font(.callout.monospacedDigit()).frame(minWidth: 44, alignment: .trailing)
                Stepper("", value: binding, in: range, step: step).labelsHidden().controlSize(.small)
            }
        }
    }
}

struct OptionSeconds: View {
    let label: String
    var help: String = ""
    let binding: Binding<Double>
    let range: ClosedRange<Double>
    var body: some View {
        OptionRow(label, help: help) {
            HStack(spacing: 8) {
                Slider(value: binding, in: range, step: 5).frame(width: 140).controlSize(.small)
                Text(fmt(binding.wrappedValue)).font(.callout.monospacedDigit()).frame(width: 52, alignment: .trailing)
            }
        }
    }
    private func fmt(_ s: Double) -> String { s < 60 ? "\(Int(s)) s" : (s.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(s / 60)) min" : "\(Int(s / 60))m \(Int(s) % 60)s") }
}

struct OptionPicker: View {
    let label: String
    var help: String = ""
    let binding: Binding<String>
    let choices: [(String, String)]     // (value, title)
    var body: some View {
        OptionRow(label, help: help) {
            Picker("", selection: binding) {
                ForEach(choices, id: \.0) { c in Text(c.1).tag(c.0) }
            }
            .labelsHidden().controlSize(.small).frame(maxWidth: 170)
        }
    }
}

struct OptionSection<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 2)
            content
        }
        .padding(.vertical, 6)
    }
}

// MARK: - The per-view Options popover

struct OptionsPopover: View {
    let nav: Nav?
    @EnvironmentObject private var options: Options

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(OptionsContent.title(for: nav)).font(.headline)
                    Spacer()
                    Button("Reset") { options.reset(prefix: OptionsContent.resetPrefix(for: nav)) }.controlSize(.small).font(.caption)
                }
                .padding(.bottom, 4)
                OptionsContent(nav: nav)
                Divider().padding(.vertical, 6)
                Text("More in Settings (⌘,) — polling, notifications, capture, export.").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(16)
        }
        .frame(width: 380)
        .frame(maxHeight: 560)
    }
}

/// The controls for one view. Used by the toolbar popover and again inside Settings.
struct OptionsContent: View {
    let nav: Nav?
    @EnvironmentObject private var options: Options
    @EnvironmentObject private var engine: CaptureEngine

    var body: some View { content }

    static func title(for nav: Nav?) -> String {
        switch nav {
        case .overview?: return "Overview options"
        case .group?: return "Tier options"
        case .net(let v)?: return "\(v.rawValue) options"
        case .actions?: return "Actions options"
        default: return "Options"
        }
    }
    static func resetPrefix(for nav: Nav?) -> String {
        switch nav {
        case .overview?: return "ov."
        case .group?: return "tier."
        case .net(.feed)?: return "feed."
        case .net(.sites)?: return "sites."
        case .net(.devices)?: return "dev."
        case .net(.apps)?: return "apps."
        case .net(.history)?: return "hist."
        case .net(.alerts)?: return "alerts."
        case .net(.scan)?: return "scan."
        case .actions?: return "act."
        default: return "zz."
        }
    }

    @ViewBuilder
    private var content: some View {
        switch nav {
        case .overview?: overview
        case .group?: tier
        case .net(.feed)?: feed
        case .net(.sites)?: sites
        case .net(.devices)?: devices
        case .net(.apps)?: apps
        case .net(.history)?: history
        case .net(.alerts)?: alerts
        case .net(.scan)?: scan
        case .net(.ask)?: Text("Ask has no options — it answers over the data the other views show.").font(.callout).foregroundStyle(.secondary)
        case .net(.policies)?: Text("Policies are managed on the page itself. Enforcement is simulated until you deploy the gateway pack.").font(.callout).foregroundStyle(.secondary)
        case .actions?: actions
        default: EmptyView()
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 0) {
            OptionSection("Sections") {
                OptionToggle(label: "Needs attention", binding: options.bind(\.ovAttention))
                OptionToggle(label: "Since you last looked", binding: options.bind(\.ovDelta))
                OptionToggle(label: "SITREP cards", binding: options.bind(\.ovSitrep))
                OptionToggle(label: "Storage & runway", binding: options.bind(\.ovStorage))
                OptionToggle(label: "Network strip", binding: options.bind(\.ovNetwork))
                OptionToggle(label: "Recent changes", binding: options.bind(\.ovChanges))
            }
            OptionSection("Attention thresholds") {
                OptionStepper(label: "Disk warning at", binding: options.bind(\.diskWarn), range: 50...98, unit: "%")
                OptionStepper(label: "Disk critical at", binding: options.bind(\.diskCrit), range: 51...99, unit: "%")
                OptionToggle(label: "Include network alerts", help: "Confirmed threats and unrecognised devices", binding: options.bind(\.attnNetwork))
                OptionToggle(label: "Flag a stale topology feed", binding: options.bind(\.attnStale))
                OptionToggle(label: "Flag a quiet capture", help: "No packets for 10 minutes while capturing", binding: options.bind(\.attnQuiet))
            }
            OptionSection("Insights") {
                OptionStepper(label: "Runway window", help: "Days of storage samples used for the estimate", binding: options.bind(\.runwayDays), range: 1...30, unit: " d")
                OptionStepper(label: "“Last looked” gap", help: "Minutes away before the delta card appears", binding: options.bind(\.deltaGapMin), range: 5...240, step: 5, unit: " min")
                OptionStepper(label: "Recent changes window", binding: options.bind(\.changesHours), range: 1...168, unit: " h")
            }
        }
    }

    private var tier: some View {
        VStack(alignment: .leading, spacing: 0) {
            OptionSection("Cards") {
                OptionToggle(label: "Compact cards", binding: options.bind(\.tierCompact))
                OptionPicker(label: "Sort", binding: options.bind(\.tierSort), choices: [("generator", "Generator order"), ("name", "Name"), ("state", "Problems first")])
                OptionToggle(label: "Problems only", help: "Hide nodes that are up and under the disk threshold", binding: options.bind(\.tierProblemsOnly))
            }
        }
    }

    private var feed: some View {
        VStack(alignment: .leading, spacing: 0) {
            OptionSection("Raw flows") {
                OptionToggle(label: "Group by category", help: "Applies to the Raw flows mode", binding: options.bind(\.feedGrouped))
            }
            OptionSection("Filters") {
                OptionToggle(label: "Hide local chatter", help: "Device-to-device traffic on your LAN", binding: options.bind(\.feedHideLocal))
                OptionToggle(label: "Hide DNS / system lookups", binding: options.bind(\.feedHideDNS))
                OptionPicker(label: "Minimum size", binding: Binding(get: { String(options.feedMinBytes) }, set: { options.feedMinBytes = Int($0) ?? 0 }),
                             choices: [("0", "Show all"), ("1024", "≥ 1 KB"), ("10240", "≥ 10 KB"), ("102400", "≥ 100 KB"), ("1048576", "≥ 1 MB")])
            }
            OptionSection("Live window") {
                OptionStepper(label: "Keep flows", help: "How many live flows stay in memory", binding: options.bind(\.feedLiveCap), range: 100...2000, step: 100)
                HStack {
                    Button("Clear live flows") { engine.clear() }.controlSize(.small)
                    Button(engine.running ? "Pause capture" : "Start capture") { engine.running ? engine.stop() : engine.start(interactive: true) }.controlSize(.small)
                }.padding(.top, 4)
            }
        }
    }

    private var sites: some View {
        let cats = ["Streaming", "Music", "Social", "Web", "Cloud / CDN", "Apple / system", "IoT telemetry", "Ad / tracker", "DNS / system"]
        return VStack(alignment: .leading, spacing: 0) {
            OptionSection("Default range") {
                OptionPicker(label: "Open on", binding: Binding(get: { String(options.sitesScope) }, set: { options.sitesScope = Int($0) ?? 0 }),
                             choices: [("0", "Today"), ("1", "Yesterday"), ("2", "Last 7 days"), ("3", "Last 30 days")])
            }
            OptionSection("Hide categories") {
                ForEach(cats, id: \.self) { c in
                    Toggle(c, isOn: Binding(get: { !options.sitesHiddenSet.contains(c) }, set: { _ in options.toggleSitesCategory(c) }))
                        .toggleStyle(.checkbox).controlSize(.small)
                }
            }
        }
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: 0) {
            OptionSection("List") {
                OptionPicker(label: "Sort", binding: options.bind(\.devSort), choices: [("flows", "Most active"), ("name", "Name"), ("firstSeen", "Newest first")])
                OptionToggle(label: "Hide unidentified devices", binding: options.bind(\.devHideUnidentified))
                OptionToggle(label: "New in the last 24 h only", binding: options.bind(\.devNewOnly))
            }
        }
    }

    private var apps: some View {
        VStack(alignment: .leading, spacing: 0) {
            OptionSection("List") {
                OptionPicker(label: "Sort", binding: options.bind(\.appsSort), choices: [("bytes", "Most data"), ("flows", "Most connections"), ("name", "Name")])
                OptionToggle(label: "Hide system daemons", help: "bird, apsd, trustd and friends", binding: options.bind(\.appsHideSystem))
                OptionToggle(label: "Only apps that hit trackers", binding: options.bind(\.appsTrackersOnly))
            }
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 0) {
            OptionSection("Chart") {
                OptionPicker(label: "Bandwidth window", binding: Binding(get: { String(options.histWindowMin) }, set: { options.histWindowMin = Int($0) ?? 30 }),
                             choices: [("15", "15 min"), ("30", "30 min"), ("60", "60 min"), ("180", "3 h")])
                OptionStepper(label: "Top talkers", binding: options.bind(\.histTopN), range: 5...50, step: 5)
            }
        }
    }

    private var alerts: some View {
        VStack(alignment: .leading, spacing: 0) {
            OptionSection("Show") {
                OptionToggle(label: "Confirmed threats", binding: options.bind(\.alertsShowConfirmed))
                OptionToggle(label: "Review-tier flows", binding: options.bind(\.alertsShowReview))
                OptionToggle(label: "Anomalies (new hardware, large uploads)", binding: options.bind(\.alertsShowAnomalies))
            }
            OptionSection("Mute heuristics") {
                OptionToggle(label: "Plaintext HTTP", help: "Stops flagging port-80 traffic", binding: options.bind(\.mutePlaintext))
                OptionToggle(label: "Unusual port to unknown host", binding: options.bind(\.muteUnusualPort))
                OptionToggle(label: "Unknown hardware joined", binding: options.bind(\.muteNewDevice))
                OptionToggle(label: "Large upload from a device", binding: options.bind(\.muteLargeUpload))
            }
            HStack {
                Button("Clear anomalies") { AnomalyStore.shared.clear() }.controlSize(.small)
            }.padding(.top, 4)
        }
    }

    private var scan: some View {
        VStack(alignment: .leading, spacing: 0) {
            OptionSection("Port scan") {
                OptionToggle(label: "Extended port set", help: "Adds 25, 53, 110, 143, 465, 587, 993, 995, 2049, 3000, 3306, 5432, 5601, 6379, 8000, 8006, 8096, 8123, 8443, 9000, 9090, 9200, 32400…", binding: options.bind(\.scanExtended))
                OptionStepper(label: "Probe timeout", binding: options.bind(\.scanTimeoutMs), range: 300...5000, step: 100, unit: " ms")
                OptionStepper(label: "Hosts in parallel", binding: options.bind(\.scanConcurrency), range: 4...64, step: 4)
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 0) {
            OptionSection("Sections") {
                OptionToggle(label: "Hosts · SSH", binding: options.bind(\.actShowHosts))
                OptionToggle(label: "Stack scripts", binding: options.bind(\.actShowScripts))
                OptionToggle(label: "Containers", binding: options.bind(\.actShowContainers))
                OptionToggle(label: "Proxmox guests", binding: options.bind(\.actShowProxmox))
            }
            OptionSection("Behaviour") {
                OptionToggle(label: "Confirm safe actions too", help: "Restart, start, scripts, refresh. Stop / shutdown / reboot always confirm.", binding: options.bind(\.actConfirmSafe))
                OptionRow("SSH user") {
                    TextField("root", text: options.bind(\.actSSHUser)).textFieldStyle(.roundedBorder).frame(width: 120).controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Settings-only bodies

struct PollingOptionsBody: View {
    @EnvironmentObject private var options: Options
    var body: some View {
        OptionSection("Polling & freshness") {
            OptionSeconds(label: "Topology poll", help: "How often topology.json is fetched", binding: options.bind(\.topologyPoll), range: 10...600)
            OptionSeconds(label: "Action service poll", binding: options.bind(\.actionsPoll), range: 15...600)
            OptionSeconds(label: "Stale after", help: "Pills turn orange when the last good poll or packet is older than this", binding: options.bind(\.staleAfter), range: 30...900)
        }
    }
}

struct CaptureOptionsBody: View {
    @EnvironmentObject private var options: Options
    @EnvironmentObject private var engine: CaptureEngine
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OptionSection("Capture") {
                OptionToggle(label: "Start network capture at launch", binding: options.bind(\.captureAtLaunch))
                OptionPicker(label: "Interface", help: "auto = the default-route interface (\(CaptureEngine.defaultInterface()))", binding: options.bind(\.capInterface),
                             choices: [("auto", "auto")] + CaptureEngine.interfaces().map { ($0, $0) })
                OptionToggle(label: "DNS sniffer", help: "Names destinations from plaintext lookups on every resolver interface", binding: options.bind(\.capDNS))
                OptionToggle(label: "mDNS / Bonjour sniffer", help: "Device names, models and services other devices announce", binding: options.bind(\.capMDNS))
                OptionToggle(label: "TLS SNI sniffer", help: "Names HTTPS destinations when DNS was cached or encrypted", binding: options.bind(\.capSNI))
                OptionToggle(label: "DHCP sniffer", help: "Hostnames and OS hints from DHCP requests", binding: options.bind(\.capDHCP))
                Text("Sniffer changes apply the next time capture starts.").font(.caption2).foregroundStyle(.tertiary)
            }
            OptionSection("Intelligence") {
                OptionToggle(label: "Download threat feeds", help: "abuse.ch Feodo + URLhaus, cached for offline use", binding: options.bind(\.capFeeds))
                OptionStepper(label: "New-device baseline", help: "Seconds of census before unknown-hardware alerts start", binding: options.bind(\.capBaselineSec), range: 10...600, step: 5, unit: " s")
                OptionStepper(label: "Keep visit logs for", binding: options.bind(\.capRetentionDays), range: 1...365, unit: " d")
            }
            HStack {
                Button(engine.running ? "Restart capture with these settings" : "Start capture") { engine.stop(); engine.start(interactive: true) }.controlSize(.small)
                Spacer()
                NetFreshnessPill(engine: engine)
            }.padding(.top, 6)
        }
    }
}

struct LocalNotifyOptionsBody: View {
    @EnvironmentObject private var options: Options
    var body: some View {
        OptionSection("macOS notifications (this Mac)") {
            OptionToggle(label: "Enabled", binding: options.bind(\.localNotifications))
            Group {
                OptionToggle(label: "Node goes down", binding: options.bind(\.nNodeDown))
                OptionToggle(label: "Node recovers / degrades", binding: options.bind(\.nNodeUp))
                OptionToggle(label: "Disk crosses a threshold", binding: options.bind(\.nDisk))
                OptionToggle(label: "SITREP card turns warn / crit", binding: options.bind(\.nSitrep))
                OptionToggle(label: "Confirmed malicious connection", binding: options.bind(\.nThreat))
                OptionToggle(label: "Unknown device joined · large upload", binding: options.bind(\.nNewDevice))
                OptionToggle(label: "Action results", help: "Restart / script / power outcomes", binding: options.bind(\.nAction))
            }
            .disabled(!options.localNotifications)
        }
    }
}

/// Server-side push rules (hatch-notify on the server), edited through the action API.
struct PushOptionsBody: View {
    @EnvironmentObject private var actions: ActionService
    private let events: [(String, String, String)] = [
        ("node_down", "Node goes down", "high priority"),
        ("node_up", "Node recovers", ""),
        ("node_warn", "Node degrades", ""),
        ("disk_warn", "Disk crosses 90 %", ""),
        ("disk_crit", "Disk crosses 95 %", "high priority"),
        ("disk_ok", "Disk back under 85 %", "low priority"),
        ("sitrep", "SITREP card changes state", ""),
        ("stale", "Topology generator stalls", ""),
    ]
    var body: some View {
        OptionSection("Phone push · ntfy (server-side, works while this Mac sleeps)") {
            if let p = actions.pushConfig {
                Toggle(isOn: Binding(get: { p.enabled }, set: { actions.updatePush(["enabled": $0]) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Push enabled").font(.callout)
                        Text("Topic “\(p.topic)” on \(p.ntfy)").font(.caption2).foregroundStyle(.secondary)
                    }
                }.toggleStyle(.switch).controlSize(.small).padding(.vertical, 2)
                Group {
                    ForEach(events, id: \.0) { e in
                        Toggle(isOn: Binding(get: { p.events[e.0] ?? true }, set: { actions.updatePush(["events": [e.0: $0]]) })) {
                            HStack { Text(e.1).font(.callout); if !e.2.isEmpty { Text(e.2).font(.caption2).foregroundStyle(.tertiary) } }
                        }.toggleStyle(.switch).controlSize(.small).padding(.vertical, 2)
                    }
                    HStack {
                        Text("Topic").font(.callout)
                        Text(p.topic).font(.callout.monospaced())
                        Text("· change it in /etc/hatch-actions/config.json").font(.caption2).foregroundStyle(.tertiary)
                    }
                }.disabled(!p.enabled)
                if !actions.pushError.isEmpty { Text(actions.pushError).font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button("Send test push") { actions.testPush() }.controlSize(.small)
                    Text(actions.pushTestResult).font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 4)
            } else {
                Text(actions.configured ? (actions.health == nil ? "Action service unreachable — push rules load from the server." : "Loading…") : "Connect the action service (Control tab) to edit push rules.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .onAppear { actions.loadPushConfig() }
    }
}

struct ExportOptionsBody: View {
    @EnvironmentObject private var options: Options
    @AppStorage("exportDataset") private var datasetRaw = ExportDataset.everything.rawValue
    @AppStorage("exportFormat") private var formatRaw = ExportFormat.json.rawValue
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OptionSection("Defaults") {
                OptionPicker(label: "Dataset", binding: $datasetRaw, choices: ExportDataset.allCases.map { ($0.rawValue, $0.rawValue) })
                OptionPicker(label: "Format", binding: $formatRaw, choices: ExportFormat.allCases.map { ($0.rawValue, $0.rawValue) })
                OptionPicker(label: "Time range", help: "Applies to changes, flows, sites, alerts and the actions log", binding: options.bind(\.expRange),
                             choices: [("all", "Everything"), ("24h", "Last 24 hours"), ("7d", "Last 7 days")])
            }
            OptionSection("Columns") {
                Text("Untick a column to leave it out of every export of that dataset.").font(.caption2).foregroundStyle(.secondary)
                ForEach(ExportDataset.allCases.filter { $0 != .everything }) { ds in
                    DisclosureGroup(ds.rawValue) {
                        let cols = ReportBuilder.columns(for: ds)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], alignment: .leading, spacing: 2) {
                            ForEach(cols, id: \.self) { c in
                                Toggle(c, isOn: Binding(get: { !options.isColumnHidden(ds.rawValue, c) }, set: { _ in options.toggleColumn(ds.rawValue, c) }))
                                    .toggleStyle(.checkbox).controlSize(.small)
                            }
                        }.padding(.vertical, 4)
                    }.font(.callout)
                }
            }
        }
    }
}
