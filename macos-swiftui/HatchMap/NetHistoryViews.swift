import SwiftUI
import Foundation
import AppKit
import Darwin
import Network
import UserNotifications

struct HistoryView: View {
    @ObservedObject var engine: CaptureEngine
    @EnvironmentObject private var options: Options
    var body: some View {
        let remotes = HistoryStore.shared.snapshotRemotes().filter { !$0.r.isPrivate && $0.r.bytes > 0 }.sorted { $0.r.bytes > $1.r.bytes }
        let devices = HistoryStore.shared.snapshotDevices().filter { $0.d.bytes > 0 }.sorted { $0.d.bytes > $1.d.bytes }
        let windowMin = max(15, options.histWindowMin)
        let topN = max(5, options.histTopN)
        let series = HistoryStore.shared.timelineSeries(minutes: windowMin)
        let maxB = max(series.max() ?? 1, 1)
        // Dedupe by display label ("Cloudflare" x3 -> one row) and color by category.
        let dests = Dictionary(grouping: remotes, by: { item -> String in
            serviceForIP(item.ip, org: item.r.org, port: item.r.port)?.name ?? bestHostForIP(item.ip)
        }).map { label, items -> (label: String, bytes: Int, cat: String, sub: String) in
            let svc = serviceForIP(items[0].ip, org: items[0].r.org, port: items[0].r.port)
            let bytes = items.reduce(0) { $0 + $1.r.bytes }
            let sub = (svc?.purpose.isEmpty == false) ? svc!.purpose
                : (items.count > 1 ? "\(items.count) endpoints" : (items[0].r.org.isEmpty ? items[0].ip : items[0].r.org))
            return (label, bytes, svc?.category ?? categoryFor(host: label, org: items[0].r.org, port: items[0].r.port), sub)
        }.sorted { $0.bytes > $1.bytes }
        let maxDest = dests.first?.bytes ?? 1
        let maxDev = devices.first?.d.bytes ?? 1
        let total = HistoryStore.shared.total
        let dur = Int(Date().timeIntervalSince(HistoryStore.shared.start))
        return ScrollView { VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 24) {
                histStat(fmtBytes(total), "total seen")
                histStat(durString(dur), "session")
                histStat("\(remotes.count)", "destinations")
                histStat("\(devices.count)", "devices")
                Spacer()
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    sectionLabel("Bandwidth — last \(windowMin) min")
                    Spacer()
                    if series.filter({ $0 > 0 }).count < 3 {
                        Text("still collecting").font(.system(size: 10)).foregroundStyle(Pal.ink3)
                    }
                }
                HStack(alignment: .bottom, spacing: windowMin > 60 ? 1 : 3) {
                    ForEach(Array(series.enumerated()), id: \.offset) { _, v in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(v > 0 ? Pal.live.opacity(0.85) : Color.primary.opacity(0.05))
                            .frame(width: windowMin > 60 ? 4 : (windowMin > 30 ? 8 : 14), height: max(3, CGFloat(Double(v) / Double(maxB)) * 62))
                    }
                }.frame(height: 66, alignment: .bottom).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(13).frame(maxWidth: .infinity, alignment: .leading).card()
            if remotes.isEmpty {
                Text("Traffic totals build up here as you use the network — this view isn't capped at the live 400 flows.")
                    .font(.system(size: 12)).foregroundStyle(Pal.ink3).padding(.top, 8)
            } else {
                Text("TOP DESTINATIONS (BY DATA)").font(.system(size: 10, weight: .semibold)).foregroundStyle(Pal.ink3).kerning(1)
                VStack(spacing: 5) {
                    ForEach(Array(dests.prefix(topN)), id: \.label) { d in
                        talkerRow(name: d.label, sub: d.sub, bytes: d.bytes,
                                  frac: Double(d.bytes) / Double(maxDest), color: categoryColor(d.cat))
                    }
                }
                Text("TOP DEVICES (BY DATA)").font(.system(size: 10, weight: .semibold)).foregroundStyle(Pal.ink3).kerning(1).padding(.top, 4)
                VStack(spacing: 5) {
                    ForEach(Array(devices.prefix(topN)), id: \.ip) { item in
                        let dc = deviceClass(item.ip); let m = resolveDevice(item.ip)
                        talkerRow(name: m.name, sub: "\(dc.klass) · \(item.ip)",
                                  bytes: item.d.bytes, frac: Double(item.d.bytes) / Double(maxDev), color: deviceColor(item.ip))
                    }
                }
            }
        }.padding(14) }
    }
    private func histStat(_ n: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(n).font(dataFont(21, .semibold)).foregroundStyle(Pal.ink)
            Text(l).font(.system(size: 10)).foregroundStyle(Pal.ink3)
        }
    }
    private func talkerRow(name: String, sub: String, bytes: Int, frac: Double, color: Color) -> some View {
        let isIP = !name.contains(where: { $0.isLetter })
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(isIP ? dataFont(12) : .system(size: 12.5, weight: .medium))
                    .foregroundStyle(isIP ? Pal.ink2 : Pal.ink).lineLimit(1)
                // don't repeat the name as its own subtitle
                if !sub.isEmpty && sub != name {
                    Text(sub).font(.system(size: 10)).foregroundStyle(Pal.ink3).lineLimit(1)
                }
            }.frame(width: 190, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.05)).frame(height: 8)
                    RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.85)).frame(width: max(3, geo.size.width * CGFloat(frac)), height: 8)
                }.frame(maxHeight: .infinity, alignment: .center)
            }.frame(height: 12)
            Text(fmtBytes(bytes)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.ink2).frame(width: 68, alignment: .trailing)
        }.padding(.vertical, 3)
    }
    private func durString(_ s: Int) -> String {
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

struct AlertsView: View {
    @ObservedObject var engine: CaptureEngine
    @ObservedObject var store = AnomalyStore.shared
    @EnvironmentObject private var options: Options
    var body: some View {
        let flagged = engine.alerts.filter { ($0.threat.hasPrefix("confirmed") && options.alertsShowConfirmed) || ($0.threat.hasPrefix("suspicious") && options.alertsShowReview) }
        let anomalies = options.alertsShowAnomalies ? store.items : []
        return Group {
            if anomalies.isEmpty && flagged.isEmpty {
                VStack(spacing: 9) { Spacer()
                    Image(systemName: "checkmark.shield").font(.system(size: 26)).foregroundStyle(Pal.ink3)
                    Text("No alerts.\nNo confirmed threats or anomalies detected.")
                        .multilineTextAlignment(.center).foregroundStyle(Pal.ink3).font(.system(size: 12.5)).lineSpacing(3)
                    Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView { LazyVStack(spacing: 7) {
                    ForEach(anomalies) { a in anomalyCard(a) }
                    if !flagged.isEmpty {
                        Text("FLAGGED FLOWS").font(.system(size: 10, weight: .semibold)).foregroundStyle(Pal.ink3).kerning(1)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6).padding(.horizontal, 2)
                        ForEach(flagged) { ev in
                            Button(action: { engine.selectedDeviceIP = ev.deviceIP; engine.selectedView = "Feed" }) { FlowRow(ev: ev, selected: false) }.buttonStyle(.plain)
                            Divider().background(Color.primary.opacity(0.05))
                        }
                    }
                }.padding(11) }
            }
        }
    }
    private func anomalyCard(_ a: Anomaly) -> some View {
        let col = a.level == "bad" ? levelColor("bad") : (a.level == "review" ? levelColor("review") : Color(red: 0.45, green: 0.62, blue: 0.95))
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: a.level == "bad" ? "exclamationmark.octagon.fill" : (a.level == "review" ? "exclamationmark.triangle.fill" : "info.circle.fill"))
                .font(.system(size: 15)).foregroundStyle(col).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Pal.ink)
                Text(a.detail).font(.system(size: 11.5)).foregroundStyle(Pal.ink2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Text(timeAgo(a.time)).font(.system(size: 10)).foregroundStyle(Pal.ink3)
        }.padding(11).frame(maxWidth: .infinity, alignment: .leading).background(Pal.panel).clipShape(RoundedRectangle(cornerRadius: 9))
    }
}
