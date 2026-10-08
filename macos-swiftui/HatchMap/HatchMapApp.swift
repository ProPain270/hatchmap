import AppKit
import SwiftUI

// MARK: - Navigation

/// The network intelligence views (formerly the NetSight app), now sections of the HatchMap sidebar.
enum NetView: String, CaseIterable, Hashable {
    case feed = "Feed", sites = "Sites", devices = "Devices", apps = "Apps"
    case ask = "Ask", history = "History", alerts = "Alerts"
    case policies = "Policies", scan = "Scan"

    var icon: String {
        switch self {
        case .feed: return "waveform.path.ecg"
        case .sites: return "globe"
        case .devices: return "laptopcomputer.and.iphone"
        case .apps: return "square.grid.2x2"
        case .ask: return "sparkles"
        case .history: return "clock.arrow.circlepath"
        case .alerts: return "bell.badge"
        case .policies: return "shield.lefthalf.filled"
        case .scan: return "dot.radiowaves.left.and.right"
        }
    }
    var subtitle: String {
        switch self {
        case .feed: return "Every connection on this Mac's network, explained in plain English"
        case .sites: return "What was visited — and from which device"
        case .devices: return "Everything on your LAN"
        case .apps: return "What's talking — confirmed on this Mac, inferred elsewhere"
        case .ask: return "Plain-English answers from live capture + visit history"
        case .history: return "Bandwidth and top talkers beyond the live window"
        case .alerts: return "Confirmed threats and anomalies"
        case .policies: return "Rules — simulated here, armed on your gateway"
        case .scan: return "Active discovery + whole-network capture"
        }
    }
    static let monitor: [NetView] = [.feed, .sites, .devices, .apps]
    static let intelligence: [NetView] = [.ask, .history, .alerts]
    static let control: [NetView] = [.policies, .scan]
}

enum Nav: Hashable {
    case overview
    case trackedDevices(DeviceCategory)
    case group(String)      // a homelab tier from topology.json
    case net(NetView)       // a network view
    case actions            // remote control

    var isHomelab: Bool {
        switch self { case .overview, .group: return true; default: return false }
    }
}

// MARK: - App

/// macOS window restoration can bring a SwiftUI app back with zero windows (it happened after
/// the 1.2 → 2.0 upgrade), which also means nothing wired to `.onAppear` ever runs. Make launch
/// deterministic: if no window is up shortly after launch, open one and come to the front.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            if Self.noMainWindow { NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil) }
            NSApp.activate(ignoringOtherApps: true)
        }
        // Belt and braces: a reopen event is exactly what `open -a HatchMap` sends, and SwiftUI
        // answers it by creating a window when there is none.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard Self.noMainWindow else { return }
            let target = NSAppleEventDescriptor(processIdentifier: ProcessInfo.processInfo.processIdentifier)
            let ev = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
                                            targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
                                            transactionID: AETransactionID(kAnyTransactionID))
            _ = try? ev.sendEvent(options: [.noReply], timeout: 2)
        }
    }
    private static var noMainWindow: Bool { NSApp.windows.filter({ $0.isVisible && $0.canBecomeMain }).isEmpty }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { true }
}

@main
struct HatchMapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var svc = TopologyService()
    @StateObject private var engine = CaptureEngine()
    @StateObject private var scanner = Scanner()
    @StateObject private var actions = ActionService()
    @StateObject private var insights = InsightStore()
    @StateObject private var options = Options.shared
    @AppStorage("veteran") private var veteran = false
    @State private var nav: Nav? = .overview
    @State private var nodeSel: HNode?
    @State private var query = ""
    @State private var showExport = false
    @State private var showOptions = false

    var body: some Scene {
        WindowGroup {
            NavigationSplitView {
                SidebarView(nav: $nav, svc: svc, engine: engine, insights: insights)
            } content: {
                ContentView(nav: nav, svc: svc, veteran: veteran, query: query, nodeSel: $nodeSel)
                    .navigationSplitViewColumnWidth(min: 560, ideal: 820)
            } detail: {
                DetailColumn(nav: nav, nodeSel: nodeSel, svc: svc, veteran: veteran)
                    .navigationSplitViewColumnWidth(min: 320, ideal: 400, max: 520)
            }
            .searchable(text: $query, prompt: searchPrompt)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await svc.load() } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Refresh now (⌘R)")
                }
                ToolbarItem {
                    Button { showOptions.toggle() } label: {
                        Label("Options", systemImage: "slider.horizontal.3")
                    }
                    .help("Options for this view (⌘⌥O)")
                    .popover(isPresented: $showOptions, arrowEdge: .bottom) {
                        OptionsPopover(nav: nav)
                            .environmentObject(options).environmentObject(engine).environmentObject(svc)
                            .environmentObject(actions).environmentObject(insights)
                    }
                }
                ToolbarItem {
                    Button { showExport = true } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .help("Export data to a file (⌘E)")
                }
                ToolbarItem {
                    Toggle("Veteran", isOn: $veteran)
                        .toggleStyle(.switch)
                        .help("Veteran = technical names · Plain = human-readable")
                }
            }
            .environmentObject(svc)
            .environmentObject(engine)
            .environmentObject(scanner)
            .environmentObject(actions)
            .environmentObject(insights)
            .environmentObject(options)
            .sheet(isPresented: $showExport) {
                ExportSheet(svc: svc, engine: engine, insights: insights, actions: actions).environmentObject(options)
            }
            .onChange(of: nav) { _, new in
                nodeSel = nil
                // Keep the network engine's own notion of "current view" in step with the sidebar;
                // the ported views navigate by setting engine.selectedView (e.g. "View flows").
                if case .net(let v)? = new, engine.selectedView != v.rawValue { engine.selectedView = v.rawValue }
            }
            .onChange(of: engine.selectedView) { _, v in
                guard let nv = NetView(rawValue: v) else { return }
                if case .net(let cur)? = nav, cur == nv { return }
                nav = .net(nv)
            }
            .onChange(of: query) { _, q in engine.search = q }
            .onAppear {
                insights.attach(svc, engine: engine)
                actions.start()
                Notifier.shared.requestAuthorization()
                if options.captureAtLaunch { engine.start() }
            }
        }
        .defaultSize(width: 1340, height: 840)
        .commands {
            // SwiftUI supplies HatchMap › Settings… (⌘,) itself; the old showSettingsWindow: selector
            // stopped working on macOS 27 ("use SettingsLink").
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .importExport) {
                Button("Export…") { showExport = true }.keyboardShortcut("e", modifiers: .command)
            }
            CommandGroup(before: .toolbar) {
                Button("Options for This View…") { showOptions.toggle() }.keyboardShortcut("o", modifiers: [.command, .option])
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await svc.load() } }.keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Overview") { nav = .overview }.keyboardShortcut("0", modifiers: .command)
                ForEach(Array(NetView.allCases.enumerated()), id: \.offset) { i, v in
                    Button(v.rawValue) { nav = .net(v); engine.deviceDetailIP = "" }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
                Button("Actions") { nav = .actions }.keyboardShortcut("a", modifiers: [.command, .shift])
            }
            CommandMenu("Capture") {
                Button(engine.running ? "Pause capture" : "Start capture") {
                    engine.running ? engine.stop() : engine.start(interactive: true)
                }.keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Clear live flows") { engine.clear() }.keyboardShortcut("k", modifiers: .command)
                Divider()
                Button("Public only") { engine.scopeFilter = "Public" }
                Button("Inbound only") { engine.scopeFilter = "Inbound" }
                Button("Show all") { engine.scopeFilter = "All" }
                Divider()
                Button(engine.remoteActive ? "Stop remote listener" : "Start remote listener") {
                    engine.remoteActive ? engine.stopRemote() : engine.startRemote()
                }
            }
        }
        Settings {
            SettingsView()
                .environmentObject(actions).environmentObject(options).environmentObject(engine)
                .environmentObject(svc).environmentObject(insights)
        }
    }

    private var searchPrompt: String {
        if case .net? = nav { return "Search host, app, device…" }
        return "Search nodes"
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Binding var nav: Nav?
    @ObservedObject var svc: TopologyService
    @ObservedObject var engine: CaptureEngine
    @ObservedObject var insights: InsightStore
    @ObservedObject private var anomalies = AnomalyStore.shared

    var body: some View {
        List(selection: $nav) {
            Section {
                Label("Overview", systemImage: "square.grid.2x2")
                    .badge(insights.attention.isEmpty ? 0 : insights.attention.count)
                    .tag(Nav.overview)
            }
            if let t = svc.topo {
                Section("Homelab") {
                    ForEach(t.groups) { g in
                        Label {
                            Text(g.tier).lineLimit(1)
                        } icon: {
                            Image(systemName: Palette.groupIcon(g.icon))
                        }
                        .badge(g.nodes.count)
                        .tag(Nav.group(g.uid))
                    }
                }
            }
            Section("Devices") {
                ForEach(DeviceCategory.allCases, id: \.self) { category in
                    Label(category.rawValue, systemImage: "laptopcomputer.and.iphone")
                        .badge((svc.topo?.trackedDevices ?? []).filter { category == .all || $0.category == category }.count)
                        .tag(Nav.trackedDevices(category))
                }
            }
            Section("Network") {
                ForEach(NetView.monitor, id: \.self) { v in row(v) }
            }
            Section("Intelligence") {
                ForEach(NetView.intelligence, id: \.self) { v in row(v) }
            }
            Section("Control") {
                Label("Actions", systemImage: "bolt.horizontal.circle").tag(Nav.actions)
                ForEach(NetView.control, id: \.self) { v in row(v) }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Hatch Homelab")
        .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 6) {
                Divider()
                FreshnessPill(svc: svc)
                CaptureControlPill(engine: engine)
            }
            .padding(.top, 2)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    @ViewBuilder
    private func row(_ v: NetView) -> some View {
        let alertCount = v == .alerts ? anomalies.items.count + engine.alerts.count : 0
        Label(v.rawValue, systemImage: v.icon)
            .badge(alertCount)
            .tag(Nav.net(v))
    }
}

/// Network freshness + play/pause in one pill — the counterpart of the topology FreshnessPill.
struct CaptureControlPill: View {
    @ObservedObject var engine: CaptureEngine
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(engine.isStale ? (engine.running ? Color.orange : Color.gray) : Color.green)
                .frame(width: 8, height: 8)
            Text(engine.staleText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button {
                engine.running ? engine.stop() : engine.start(interactive: true)
            } label: {
                Image(systemName: engine.running ? "pause.fill" : "play.fill")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help(engine.running ? "Pause network capture" : "Start network capture")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.card)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
    }
}

// MARK: - Content

struct ContentView: View {
    let nav: Nav?
    @ObservedObject var svc: TopologyService
    let veteran: Bool
    let query: String
    @Binding var nodeSel: HNode?

    var body: some View {
        switch nav {
        case .trackedDevices(let category)?:
            TrackedDevicesView(svc: svc, category: category, query: query)
        case .net(let v)?:
            NetworkContent(view: v)
        case .actions?:
            ActionsView()
        default:
            homelab
        }
    }

    @ViewBuilder
    private var homelab: some View {
        if let t = svc.topo {
            if !svc.error.isEmpty {
                ScrollView {
                    VStack(spacing: 16) {
                        SchemaBanner(text: svc.error)
                        mainContent(t)
                    }
                    .padding()
                }
            } else {
                mainContent(t)
            }
        } else if !svc.error.isEmpty {
            ContentUnavailableView("No data", systemImage: "wifi.slash", description: Text(svc.error))
        } else {
            ProgressView("Connecting…")
        }
    }

    @ViewBuilder
    private func mainContent(_ t: Topology) -> some View {
        let results = t.search(query)
        if !results.isEmpty {
            SearchResults(results: results, veteran: veteran, nodeSel: $nodeSel, query: query)
        } else {
            switch nav {
            case .group(let uid)?:
                if let g = t.groups.first(where: { $0.uid == uid }) {
                    TierView(group: g, veteran: veteran, nodeSel: $nodeSel)
                } else {
                    OverviewView(topo: t, svc: svc, veteran: veteran, nodeSel: $nodeSel)
                }
            default:
                OverviewView(topo: t, svc: svc, veteran: veteran, nodeSel: $nodeSel)
            }
        }
    }
}

struct TierView: View {
    let group: HGroup
    let veteran: Bool
    @Binding var nodeSel: HNode?
    @EnvironmentObject private var options: Options

    private var nodes: [HNode] {
        var ns = group.nodes
        if options.tierProblemsOnly { ns = ns.filter { $0.state != "up" || ($0.pct ?? 0) >= options.diskWarn } }
        switch options.tierSort {
        case "name": ns.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case "state": ns.sort { rank($0) < rank($1) }
        default: break
        }
        return ns
    }
    private func rank(_ n: HNode) -> Int { n.state == "down" ? 0 : (n.state != "up" ? 1 : ((n.pct ?? 0) >= options.diskWarn ? 2 : 3)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: Palette.groupIcon(group.icon))
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(group.tier)
                        .font(.largeTitle.bold())
                    Spacer()
                    Text(options.tierProblemsOnly ? "\(nodes.count) of \(group.nodes.count) nodes" : "\(group.nodes.count) nodes")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if nodes.isEmpty {
                    Label("Nothing needs attention in this tier", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).padding(12)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: options.tierCompact ? 170 : 220, maximum: options.tierCompact ? 240 : 340))], spacing: options.tierCompact ? 8 : 12) {
                    ForEach(nodes) { n in
                        NodeCard(node: n, group: group, veteran: veteran,
                                 selected: nodeSel?.uid == n.uid, compact: options.tierCompact) {
                            nodeSel = n
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle(group.tier)
    }
}

struct SearchResults: View {
    let results: [(group: HGroup, node: HNode)]
    let veteran: Bool
    @Binding var nodeSel: HNode?
    let query: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(results.count) result\(results.count == 1 ? "" : "s") for “\(query)”")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 340))], spacing: 12) {
                    ForEach(results, id: \.node.uid) { item in
                        NodeCard(node: item.node, group: item.group, veteran: veteran,
                                 selected: nodeSel?.uid == item.node.uid) {
                            nodeSel = item.node
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Search")
    }
}

// MARK: - Detail

struct DetailColumn: View {
    let nav: Nav?
    let nodeSel: HNode?
    @ObservedObject var svc: TopologyService
    let veteran: Bool

    var body: some View {
        switch nav {
        case .trackedDevices?:
            TrackedDeviceDetail(svc: svc, veteran: veteran)
        case .net(let v)?:
            NetDetailColumn(view: v)
        case .actions?:
            ActionLogPanel()
        default:
            if let n = nodeSel, let t = svc.topo {
                let tier = t.groups.first(where: { g in
                    g.nodes.contains(where: { $0.uid == n.uid })
                })?.tier ?? ""
                NodeDetail(node: n, groupTier: tier, veteran: veteran)
                    .id(n.uid)
            } else {
                ContentUnavailableView("Select a node", systemImage: "sidebar.right",
                                       description: Text("Choose a service from the list to inspect it here."))
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage("apiURL") private var apiURL = ""
    @AppStorage("actionsURL") private var actionsURL = ""
    @AppStorage("actionsToken") private var actionsToken = ""
    @AppStorage("pveHost") private var pveHost = ""
    @AppStorage("pveTokenID") private var pveTokenID = ""
    @AppStorage("pveSecret") private var pveSecret = ""
    @EnvironmentObject private var actions: ActionService
    @EnvironmentObject private var options: Options

    var body: some View {
        TabView {
            settingsPage {
                OptionSection("Topology feed") {
                    TextField("Topology URL", text: $apiURL, prompt: Text(TopologyService.defaultEndpoint)).textFieldStyle(.roundedBorder)
                    Text("Empty = default tailnet endpoint. Takes effect on the next poll.").font(.caption2).foregroundStyle(.secondary)
                }
                PollingOptionsBody()
                OptionSection("Startup") {
                    OptionToggle(label: "Start network capture at launch", binding: options.bind(\.captureAtLaunch))
                }
            }
            .tabItem { Label("General", systemImage: "gear") }

            settingsPage {
                OptionsContent(nav: .overview)
                Divider().padding(.vertical, 4)
                Text("Homelab tiers").font(.headline)
                OptionsContent(nav: .group(""))
            }
            .tabItem { Label("Overview", systemImage: "square.grid.2x2") }

            settingsPage {
                CaptureOptionsBody()
                Divider().padding(.vertical, 4)
                Text("Feed").font(.headline)
                OptionsContent(nav: .net(.feed))
                Divider().padding(.vertical, 4)
                Text("Scan").font(.headline)
                OptionsContent(nav: .net(.scan))
            }
            .tabItem { Label("Network", systemImage: "waveform.path.ecg") }

            settingsPage {
                LocalNotifyOptionsBody()
                Divider().padding(.vertical, 4)
                PushOptionsBody()
                Divider().padding(.vertical, 4)
                Text("Alerts view").font(.headline)
                OptionsContent(nav: .net(.alerts))
            }
            .tabItem { Label("Alerts & Push", systemImage: "bell.badge") }

            settingsPage {
                OptionSection("Action service (server)") {
                    TextField("Action service URL", text: $actionsURL, prompt: Text(ActionService.defaultEndpoint)).textFieldStyle(.roundedBorder)
                    SecureField("Action token", text: $actionsToken, prompt: Text(actions.tokenFromFile ? "read from Application Support/HatchMap/actions-token" : "paste the token from /etc/hatch-actions/token")).textFieldStyle(.roundedBorder)
                    HStack(spacing: 6) {
                        Circle().fill(actions.health == nil ? Color.orange : Color.green).frame(width: 8, height: 8)
                        Text(actions.statusText).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Test") { actions.refreshNow() }.controlSize(.small)
                    }
                }
                OptionSection("Proxmox") {
                    TextField("Proxmox host", text: $pveHost, prompt: Text(ProxmoxClient.defaultHost)).textFieldStyle(.roundedBorder)
                    TextField("API token ID", text: $pveTokenID, prompt: Text("api@pam!hatchmap")).textFieldStyle(.roundedBorder)
                    SecureField("Token secret", text: $pveSecret).textFieldStyle(.roundedBorder)
                    HStack(spacing: 6) {
                        Circle().fill(actions.pve.configured ? (actions.pve.error.isEmpty && actions.pve.lastOK != nil ? Color.green : Color.orange) : Color.gray).frame(width: 8, height: 8)
                        Text(actions.pve.configured ? (actions.pve.error.isEmpty ? (actions.pve.lastOK == nil ? "Connecting…" : "Live · \(actions.pve.guests.count) guest\(actions.pve.guests.count == 1 ? "" : "s")") : actions.pve.error) : "Not configured")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Test") { actions.refreshNow() }.controlSize(.small)
                    }
                    Text("Least-privilege token (VM.PowerMgmt · VM.Audit · Sys.Audit). Rotate with the pveum commands in README.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Divider().padding(.vertical, 4)
                Text("Actions view").font(.headline)
                OptionsContent(nav: .actions)
            }
            .tabItem { Label("Control", systemImage: "bolt.horizontal.circle") }

            settingsPage { ExportOptionsBody() }
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
        }
        .frame(width: 620, height: 640)
        .onChange(of: actionsURL) { _, _ in actions.refreshNow() }
        .onChange(of: actionsToken) { _, _ in actions.refreshNow() }
        .onChange(of: pveSecret) { _, _ in actions.refreshNow() }
        .onChange(of: pveTokenID) { _, _ in actions.refreshNow() }
    }

    private func settingsPage<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ScrollView { VStack(alignment: .leading, spacing: 4) { content() }.padding(18).frame(maxWidth: .infinity, alignment: .leading) }
    }
}
