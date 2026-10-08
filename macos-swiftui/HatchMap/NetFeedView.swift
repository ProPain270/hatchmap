import AppKit
import SwiftUI

// MARK: - Network section host
//
// NetSight's root view owned its own sidebar, header and inspector. Inside HatchMap the sidebar
// is shared, so this file keeps only the per-view header (title, freshness pill, Feed controls),
// the capture-failure banner, and the Feed's list modes. The inspector moved to the detail column.

struct NetFreshnessPill: View {
    @ObservedObject var engine: CaptureEngine
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(engine.isStale ? (engine.running ? Color.orange : Color.gray) : Color.green)
                .frame(width: 8, height: 8)
            Text(engine.staleText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.card)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
    }
}

struct NetworkContent: View {
    let view: NetView
    @EnvironmentObject private var engine: CaptureEngine
    @EnvironmentObject private var scanner: Scanner

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if engine.status.hasPrefix("Capture access denied") || engine.status.hasPrefix("Failed") { captureBanner }
            content
        }
        .navigationTitle(view.rawValue)
        .onAppear { if engine.selectedView != view.rawValue { engine.selectedView = view.rawValue } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(view.rawValue).font(.system(size: 22, weight: .bold))
                Text(view.subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            if view == .feed {
                HStack(spacing: 2) {
                    ForEach([("Destinations", false), ("Raw flows", true)], id: \.0) { label, raw in
                        Button(action: { engine.rawFeed = raw; engine.selectedFlowID = nil }) {
                            Text(label).font(.system(size: 10.5, weight: engine.rawFeed == raw ? .semibold : .regular))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(engine.rawFeed == raw ? Color.primary.opacity(0.10) : Color.clear)
                                .foregroundStyle(engine.rawFeed == raw ? Pal.ink : Pal.ink3)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain)
                    }
                }.padding(3).background(Color.primary.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 2) {
                    ForEach(["All", "Public", "Local", "Inbound"], id: \.self) { s in
                        Button(action: { engine.scopeFilter = s }) {
                            Text(s).font(.system(size: 10.5, weight: engine.scopeFilter == s ? .semibold : .regular))
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(engine.scopeFilter == s ? Color.primary.opacity(0.10) : Color.clear)
                                .foregroundStyle(engine.scopeFilter == s ? Pal.ink : Pal.ink3)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain)
                    }
                }.padding(3).background(Color.primary.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            NetFreshnessPill(engine: engine)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    /// The one failure the network half depends on: no packet-capture privilege.
    private var captureBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(Pal.warn)
            VStack(alignment: .leading, spacing: 2) {
                Text("HatchMap can't capture network traffic").font(.system(size: 12, weight: .semibold)).foregroundStyle(Pal.ink)
                Text("tcpdump needs a one-time admin approval (installs /etc/sudoers.d/netsight for tcpdump only). The homelab map keeps working without it.")
                    .font(.system(size: 10.5)).foregroundStyle(Pal.ink2)
            }
            Spacer()
            Button(action: { engine.start(interactive: true) }) {
                Text("Enable capture").font(.system(size: 11, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Pal.warn.opacity(0.9)).foregroundStyle(Pal.badgeInk).clipShape(RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Pal.warn.opacity(0.10))
        .overlay(Rectangle().fill(Pal.warn).frame(width: 3), alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch view {
        case .ask: AskView(engine: engine)
        case .sites: SitesView(engine: engine)
        case .devices:
            if engine.deviceDetailIP.isEmpty { DevicesView(engine: engine) }
            else { DeviceDetailView(engine: engine, ip: engine.deviceDetailIP) }
        case .apps: AppsView(events: engine.events)
        case .history: HistoryView(engine: engine)
        case .policies: PoliciesView(engine: engine)
        case .scan: ScanView(scanner: scanner, engine: engine)
        case .alerts: AlertsView(engine: engine)
        case .feed: FeedListView(engine: engine)
        }
    }
}

// MARK: - Feed list (destinations / raw / grouped by category)

struct FeedListView: View {
    @ObservedObject var engine: CaptureEngine
    @EnvironmentObject private var options: Options
    @State private var expandedGroup = ""
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            if !engine.selectedDeviceIP.isEmpty { deviceBanner }
            if !engine.rawFeed { destinationList }
            else if options.feedGrouped { groupedFlowList }
            else { flowListPane }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Default Feed: one row per destination, expandable into the raw flows behind it.
    private var destinationList: some View {
        let groups = destGroups(engine.filtered)
        let maxB = groups.first?.bytes ?? 1
        return Group {
            if groups.isEmpty {
                emptyState("antenna.radiowaves.left.and.right")
            } else {
                ScrollView { LazyVStack(spacing: 0) {
                    ForEach(groups) { g in
                        Button(action: {
                            if expandedGroup == g.key { expandedGroup = ""; engine.selectedFlowID = nil }
                            else { expandedGroup = g.key; engine.selectedFlowID = g.events.first?.id }
                        }) {
                            DestGroupRow(g: g, maxBytes: maxB, expanded: expandedGroup == g.key)
                        }.buttonStyle(.plain)
                        if expandedGroup == g.key {
                            VStack(spacing: 0) {
                                ForEach(g.events.prefix(12)) { ev in
                                    Button(action: { engine.selectedFlowID = ev.id }) {
                                        FlowRow(ev: ev, selected: ev.id == engine.selectedFlowID)
                                    }.buttonStyle(.plain)
                                }
                                if g.events.count > 12 {
                                    Text("+ \(g.events.count - 12) more connections").font(.system(size: 10.5))
                                        .foregroundStyle(Pal.ink3).frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.leading, 59).padding(.vertical, 5)
                                }
                            }.padding(.leading, 8).background(Color.primary.opacity(0.04))
                        }
                        Divider()
                    }
                } }
            }
        }
    }

    private var flowListPane: some View {
        let items = engine.filtered
        return Group {
            if items.isEmpty {
                emptyState("antenna.radiowaves.left.and.right")
            } else {
                ScrollView { LazyVStack(spacing: 0) {
                    ForEach(items) { ev in
                        Button(action: { engine.selectedFlowID = ev.id }) { FlowRow(ev: ev, selected: ev.id == engine.selectedFlowID) }.buttonStyle(.plain)
                        Divider()
                    }
                } }
            }
        }
    }

    private var groupedFlowList: some View {
        let items = engine.filtered
        let groups = Dictionary(grouping: items, by: { $0.category })
        let order = ["Streaming", "Music", "Social", "Web", "Cloud / CDN", "Apple / system", "IoT telemetry", "Ad / tracker", "DNS / system", "Local"]
        let keys = order.filter { groups[$0] != nil } + groups.keys.filter { !order.contains($0) }.sorted()
        return Group {
            if items.isEmpty {
                emptyState("rectangle.3.group")
            } else {
                ScrollView { LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(keys, id: \.self) { cat in
                        let flows = groups[cat] ?? []
                        let bytes = flows.reduce(0) { $0 + volumeOf($1).total }
                        Section(header: sectionHeader(cat, flows.count, bytes)) {
                            if !collapsed.contains(cat) {
                                ForEach(flows) { ev in
                                    Button(action: { engine.selectedFlowID = ev.id }) { FlowRow(ev: ev, selected: ev.id == engine.selectedFlowID) }.buttonStyle(.plain)
                                    Divider()
                                }
                            }
                        }
                    }
                } }
            }
        }
    }

    private func sectionHeader(_ cat: String, _ n: Int, _ bytes: Int) -> some View {
        Button(action: { if collapsed.contains(cat) { collapsed.remove(cat) } else { collapsed.insert(cat) } }) {
            HStack(spacing: 8) {
                Image(systemName: collapsed.contains(cat) ? "chevron.right" : "chevron.down").font(.system(size: 9)).foregroundStyle(Pal.ink3).frame(width: 10)
                Circle().fill(categoryColor(cat)).frame(width: 8, height: 8)
                Text(cat).font(.system(size: 12, weight: .semibold)).foregroundStyle(Pal.ink)
                Text("\(n) flow\(n == 1 ? "" : "s")").font(.system(size: 10.5)).foregroundStyle(Pal.ink3)
                Spacer()
                if bytes > 0 { Text(fmtBytes(bytes)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Pal.ink2) }
            }.padding(.horizontal, 14).padding(.vertical, 8).background(Pal.rail).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func emptyState(_ icon: String) -> some View {
        VStack(spacing: 9) {
            Spacer()
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(Pal.ink3)
            Text(engine.running ? "Waiting for traffic…\nBrowse something and it'll appear here." : "Press play in the sidebar to start capturing.")
                .foregroundStyle(Pal.ink2).font(.system(size: 12.5)).multilineTextAlignment(.center).lineSpacing(3)
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deviceBanner: some View {
        HStack(spacing: 8) {
            Circle().fill(deviceColor(engine.selectedDeviceIP)).frame(width: 9, height: 9)
            Text("Filtered to \(deviceLabel(engine.selectedDeviceIP))  ·  \(engine.selectedDeviceIP)")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.ink)
            Spacer()
            Button(action: { engine.selectedDeviceIP = "" }) {
                Text("Clear").font(.system(size: 11)).foregroundStyle(Pal.bad)
            }.buttonStyle(.plain)
        }.padding(.horizontal, 14).padding(.vertical, 7).background(Color.primary.opacity(0.05))
    }
}

// MARK: - Detail column for the Network section

struct NetDetailColumn: View {
    let view: NetView
    @EnvironmentObject private var engine: CaptureEngine

    var body: some View {
        Group {
            switch view {
            case .feed, .alerts:
                if let id = engine.selectedFlowID, let ev = engine.events.first(where: { $0.id == id }) {
                    DetailInspector(event: ev)
                } else {
                    NowPanel(engine: engine)
                }
            default:
                NetworkStatusPanel(engine: engine)
            }
        }
    }
}

/// Resting state of the detail column for non-Feed network views: what the capture is doing.
struct NetworkStatusPanel: View {
    @ObservedObject var engine: CaptureEngine
    @ObservedObject private var anomalies = AnomalyStore.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Network capture").font(.title2.bold())
                NetFreshnessPill(engine: engine)
                DetailSection(title: "Capture") {
                    FactRow(label: "Status", value: engine.status)
                    FactRow(label: "Interface", value: engine.iface)
                    FactRow(label: "Live flows", value: "\(engine.events.count)")
                    FactRow(label: "Devices", value: "\(engine.deviceInventory.count)")
                    FactRow(label: "Session total", value: fmtBytes(HistoryStore.shared.total))
                    let c = ThreatDB.shared.counts
                    FactRow(label: "Threat indicators", value: "\(c.ips + c.domains)")
                }
                DetailSection(title: "Collectors") {
                    if engine.collectors.isEmpty {
                        Text("None — add an SSH collector on the Scan page to see every device's traffic, not just this Mac's.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(engine.collectors) { c in
                        HStack {
                            Circle().fill(c.status == "connected" ? Pal.live : (c.status == "error" ? Pal.bad : Pal.ink3)).frame(width: 7, height: 7)
                            Text(c.id).font(.callout.monospaced())
                            Spacer()
                            Text(c.status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if engine.remoteActive {
                        FactRow(label: "Push listener", value: ":\(engine.remotePort) · \(engine.remotePeers) peer\(engine.remotePeers == 1 ? "" : "s")")
                    }
                }
                DetailSection(title: "Alerts") {
                    let bad = anomalies.items.filter { $0.level == "bad" }.count
                    FactRow(label: "Confirmed", value: "\(bad + engine.alerts.filter { $0.threat.hasPrefix("confirmed") }.count)")
                    FactRow(label: "Review", value: "\(anomalies.items.count - bad + engine.alerts.filter { $0.threat.hasPrefix("suspicious") }.count)")
                    if anomalies.isLearning {
                        Text("Learning what's normal — unknown-hardware alerts start after the census.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
        }
    }
}
