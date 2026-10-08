import SwiftUI

// MARK: - Overview — problems first, calm when healthy

struct OverviewView: View {
    let topo: Topology
    @ObservedObject var svc: TopologyService
    let veteran: Bool
    @Binding var nodeSel: HNode?
    @EnvironmentObject private var insights: InsightStore
    @EnvironmentObject private var engine: CaptureEngine
    @EnvironmentObject private var actions: ActionService
    @EnvironmentObject private var options: Options

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Overview").font(.largeTitle.bold())
                        Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    FreshnessPill(svc: svc)
                }

                // 1. Needs attention — above everything else. Calm "all clear" when there is nothing.
                if !options.ovAttention {
                    EmptyView()
                } else if insights.attention.isEmpty {
                    AllClearCard(topo: topo, engine: engine)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text("Needs attention").font(.headline)
                            Text("\(insights.attention.count)")
                                .font(.caption.bold())
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(worstColor.opacity(0.18))
                                .foregroundStyle(worstColor)
                                .clipShape(Capsule())
                        }
                        ForEach(insights.attention) { item in
                            AttentionItemRow(item: item) { select(item) }
                        }
                    }
                }

                // 2. What changed since you last looked.
                if options.ovDelta, !insights.delta.isEmpty, let since = insights.deltaSince {
                    DeltaCard(changes: insights.delta, since: since) { insights.dismissDelta() }
                }

                // 3. SITREP
                if options.ovSitrep {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))], spacing: 12) {
                        ForEach(topo.sitrep) { s in SitrepCard(s: s) }
                    }
                }

                // 4. Storage with runway in days.
                if options.ovStorage, !topo.storage.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Storage").font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240))], spacing: 12) {
                            ForEach(topo.storage, id: \.node.uid) { item in
                                StorageCard(node: item.node, group: item.group, veteran: veteran,
                                            runway: insights.runway(for: "\(item.group.tier)/\(item.node.name)"),
                                            selected: nodeSel?.uid == item.node.uid) {
                                    nodeSel = item.node
                                }
                            }
                        }
                    }
                }

                // 5. Network at a glance — one strip, links into the Network section.
                if options.ovNetwork { NetworkStrip(engine: engine) }

                // 6. Recent changes across the map (window is an option).
                let recent = insights.recentChanges.filter { Date().timeIntervalSince($0.time) < Double(options.changesHours) * 3600 }
                if options.ovChanges, !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Changes in the last \(options.changesHours)h").font(.headline)
                        VStack(spacing: 0) {
                            ForEach(recent.prefix(12)) { c in
                                HStack(spacing: 10) {
                                    Circle().fill(c.isBad ? Color.red : Color.green).frame(width: 7, height: 7)
                                    Text(c.text).font(.callout)
                                    Spacer()
                                    Text(timeAgo(c.time)).font(.caption).foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 6).padding(.horizontal, 12)
                                if c.id != recent.prefix(12).last?.id { Divider() }
                            }
                        }
                        .background(Theme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Overview")
    }

    private var subtitle: String {
        let m = topo.meta
        let host = m.tailnet.isEmpty ? m.node : m.tailnet
        return host.isEmpty ? "Live homelab topology" : host
    }
    private var worstColor: Color {
        switch insights.attention.first?.severity {
        case .crit?: return .red
        case .warn?: return .orange
        default: return .blue
        }
    }
    private func select(_ item: AttentionItem) {
        switch item.target {
        case .node(let n): nodeSel = n
        case .net(let v): engine.selectedView = v.rawValue
        case .none: break
        }
    }
}

struct AllClearCard: View {
    let topo: Topology
    @ObservedObject var engine: CaptureEngine
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 34))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                Text("All clear").font(.title2.bold())
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Color.green.opacity(0.25), lineWidth: 1))
    }
    private var summary: String {
        let nodes = topo.groups.reduce(0) { $0 + $1.nodes.count }
        var bits = ["\(nodes) nodes up"]
        if let s = topo.sitrep.first(where: { $0.l.lowercased().contains("service") }) { bits[0] = "\(s.v) services · \(nodes) nodes up" }
        if !topo.storage.isEmpty { bits.append("\(topo.storage.count) disks below \(Options.shared.diskWarn)%") }
        bits.append(engine.running ? "network capture live, no confirmed threats" : "no confirmed network threats")
        return bits.joined(separator: " · ")
    }
}

struct AttentionItemRow: View {
    let item: AttentionItem
    let onSelect: () -> Void
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: item.icon)
                    .foregroundStyle(color)
                    .frame(width: 26, height: 26)
                    .background(color.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.callout.weight(.medium))
                    if !item.detail.isEmpty {
                        Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                Text(label).font(.caption2.weight(.semibold)).foregroundStyle(color)
                if hasTarget { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
            }
            .padding(.vertical, 8).padding(.horizontal, 12)
            .background(color.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!hasTarget)
    }
    private var hasTarget: Bool { if case .none = item.target { return false }; return true }
    private var color: Color {
        switch item.severity { case .crit: return .red; case .warn: return .orange; case .info: return .blue }
    }
    private var label: String {
        switch item.severity { case .crit: return "CRITICAL"; case .warn: return "WARNING"; case .info: return "INFO" }
    }
}

struct DeltaCard: View {
    let changes: [ChangeItem]
    let since: Date
    let onDismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Since you last looked", systemImage: "clock.arrow.2.circlepath").font(.headline)
                Text("· \(timeAgo(since))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Dismiss", action: onDismiss).buttonStyle(.borderless).font(.caption)
            }
            ForEach(changes.prefix(10)) { c in
                HStack(spacing: 8) {
                    Image(systemName: c.isBad ? "arrow.down.right.circle.fill" : "arrow.up.right.circle.fill")
                        .foregroundStyle(c.isBad ? .red : .green)
                    Text(c.text).font(.callout)
                    Spacer()
                }
            }
            if changes.count > 10 {
                Text("+ \(changes.count - 10) more").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.blue.opacity(0.2), lineWidth: 1))
    }
}

struct StorageCard: View {
    let node: HNode
    let group: HGroup
    let veteran: Bool
    let runway: RunwayEstimate?
    let selected: Bool
    let onSelect: () -> Void
    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(Palette.color("store"))
                        .font(.title3)
                        .frame(width: 30, height: 30)
                        .background(Palette.color("store").opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(node.name).font(.headline).lineLimit(1)
                        Text(node.meta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    StatusDot(state: node.state)
                }
                if let p = node.pct { StorageBar(pct: p, free: node.free) }
                HStack(spacing: 6) {
                    Image(systemName: runway?.days == nil ? "checkmark.circle" : "hourglass")
                        .font(.caption)
                    Text(runway?.text ?? "runway: collecting samples…")
                        .font(.caption.weight(.medium))
                    if let r = runway {
                        Text("· \(r.confidence)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .foregroundStyle(runwayColor)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.selected : Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                .stroke(selected ? Color.accentColor.opacity(0.5) : Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
    private var runwayColor: Color {
        guard let d = runway?.days else { return .secondary }
        if d < 7 { return .red }
        if d < 30 { return .orange }
        return .secondary
    }
}

/// One line of network status on the Overview; every number links into the Network section.
struct NetworkStrip: View {
    @ObservedObject var engine: CaptureEngine
    @ObservedObject private var anomalies = AnomalyStore.shared
    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle().fill(engine.isStale ? (engine.running ? Color.orange : Color.gray) : Color.green).frame(width: 8, height: 8)
                Text("Network · \(engine.staleText)").font(.callout.weight(.medium))
            }
            Spacer()
            stat("\(engine.events.count)", "live flows", .feed)
            stat("\(engine.deviceInventory.count)", "devices", .devices)
            stat("\(anomalies.items.count + engine.alerts.count)", "alerts", .alerts)
            stat(fmtBytes(HistoryStore.shared.total), "this session", .history)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
    }
    private func stat(_ n: String, _ l: String, _ v: NetView) -> some View {
        Button { engine.selectedView = v.rawValue } label: {
            HStack(spacing: 4) {
                Text(n).font(.callout.weight(.semibold).monospacedDigit())
                Text(l).font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
