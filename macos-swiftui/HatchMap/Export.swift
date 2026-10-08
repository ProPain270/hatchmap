import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import CoreText

// MARK: - Export
//
// File → Export… (⌘E). Pick what (a dataset or everything) and the format at export time;
// the save panel does the rest. One report model, five renderers.

enum ExportDataset: String, CaseIterable, Identifiable {
    case everything = "Everything"
    case attention = "Needs attention"
    case topology = "Topology (all nodes)"
    case sitrep = "SITREP"
    case changes = "Changes (7 days)"
    case netFlows = "Network · live flows"
    case netDevices = "Network · devices"
    case netSites = "Network · sites (7 days)"
    case netHistory = "Network · top talkers"
    case netAlerts = "Network · alerts"
    case actionsLog = "Actions log"
    var id: String { rawValue }
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case json = "JSON", csv = "CSV", markdown = "Markdown", html = "HTML", pdf = "PDF"
    var id: String { rawValue }
    var ext: String {
        switch self { case .json: return "json"; case .csv: return "csv"; case .markdown: return "md"; case .html: return "html"; case .pdf: return "pdf" }
    }
    var type: UTType {
        switch self {
        case .json: return .json
        case .csv: return .commaSeparatedText
        case .markdown: return UTType(filenameExtension: "md") ?? .plainText
        case .html: return .html
        case .pdf: return .pdf
        }
    }
}

struct ReportSection {
    var title: String
    var note: String = ""
    var columns: [String]
    var rows: [[String]]
}

struct Report {
    var title: String
    var generated = Date()
    var source: String
    var sections: [ReportSection]
}

// MARK: builder

struct ReportBuilder {
    let svc: TopologyService
    let engine: CaptureEngine
    let insights: InsightStore
    let actions: ActionService
    private let iso = ISO8601DateFormatter()

    func build(_ ds: ExportDataset) -> Report {
        let all: [ExportDataset] = ds == .everything ? ExportDataset.allCases.filter { $0 != .everything } : [ds]
        let src = svc.topo?.meta.tailnet ?? svc.endpoint.host(percentEncoded: false) ?? "HatchMap"
        return Report(title: ds == .everything ? "HatchMap — full export" : "HatchMap — \(ds.rawValue)",
                      source: src, sections: all.map { applyOptions(section($0), $0) })
    }

    /// Column names each dataset produces — the Export settings tab offers these as checkboxes.
    static func columns(for ds: ExportDataset) -> [String] {
        switch ds {
        case .everything: return []
        case .attention: return ["severity", "title", "detail"]
        case .topology: return ["tier", "name", "type", "state", "meta", "exposure", "pct", "free", "url", "plain", "tech"]
        case .sitrep: return ["label", "value", "sub", "state"]
        case .changes: return ["time", "node", "from", "to", "kind"]
        case .netFlows: return ["time", "direction", "device", "app", "host", "org", "country", "category", "proto", "port", "bytes", "threat"]
        case .netDevices: return ["ip", "name", "class", "os", "type", "vendor", "mac", "flows", "destinations", "first_seen", "last_seen"]
        case .netSites: return ["domain", "category", "devices", "visits", "bytes", "first", "last"]
        case .netHistory: return ["remote", "name", "service", "org", "port", "bytes", "hits", "last"]
        case .netAlerts: return ["time", "level", "title", "detail", "device"]
        case .actionsLog: return ["time", "target", "op", "ok", "message"]
        }
    }

    /// Hidden columns and the time range from Options, applied uniformly.
    private func applyOptions(_ sec: ReportSection, _ ds: ExportDataset) -> ReportSection {
        var out = sec
        let o = Options.shared
        // Time range on datasets that carry a timestamp column.
        let cutoff: Date? = o.expRange == "24h" ? Date().addingTimeInterval(-86_400) : (o.expRange == "7d" ? Date().addingTimeInterval(-7 * 86_400) : nil)
        if let cutoff, let ti = out.columns.firstIndex(where: { $0 == "time" || $0 == "last" || $0 == "last_seen" }) {
            out.rows = out.rows.filter { row in ti < row.count ? (iso.date(from: row[ti]).map { $0 >= cutoff } ?? true) : true }
            out.note = (out.note.isEmpty ? "" : out.note + " · ") + (o.expRange == "24h" ? "last 24 hours" : "last 7 days")
        }
        let hidden = out.columns.enumerated().filter { o.isColumnHidden(ds.rawValue, $0.element) }.map(\.offset)
        if !hidden.isEmpty {
            out.columns = out.columns.enumerated().filter { !hidden.contains($0.offset) }.map(\.element)
            out.rows = out.rows.map { r in r.enumerated().filter { !hidden.contains($0.offset) }.map(\.element) }
        }
        return out
    }

    private func section(_ ds: ExportDataset) -> ReportSection {
        switch ds {
        case .everything: return ReportSection(title: "—", columns: [], rows: [])
        case .attention:
            return ReportSection(title: "Needs attention", note: insights.attention.isEmpty ? "All clear." : "",
                                 columns: ["severity", "title", "detail"],
                                 rows: insights.attention.map { [sevName($0.severity), $0.title, $0.detail] })
        case .topology:
            var rows: [[String]] = []
            for g in svc.topo?.groups ?? [] {
                for n in g.nodes {
                    rows.append([g.tier, n.name, n.t, n.state, n.meta, n.expo ?? "", n.pct.map(String.init) ?? "", n.free ?? "", n.url ?? "", n.plain, n.tech])
                }
            }
            let m = svc.topo?.meta
            return ReportSection(title: "Topology", note: m.map { "node \($0.node) · updated \($0.updated) · schema v\($0.schema ?? 1)" } ?? "no data",
                                 columns: ["tier", "name", "type", "state", "meta", "exposure", "pct", "free", "url", "plain", "tech"], rows: rows)
        case .sitrep:
            return ReportSection(title: "SITREP", columns: ["label", "value", "sub", "state"],
                                 rows: (svc.topo?.sitrep ?? []).map { [$0.l, $0.v, $0.s, $0.c] })
        case .changes:
            return ReportSection(title: "Changes (7 days)", columns: ["time", "node", "from", "to", "kind"],
                                 rows: insights.recentChanges.map { [iso.string(from: $0.time), $0.key, $0.from, $0.to, $0.kind] })
        case .netFlows:
            return ReportSection(title: "Network · live flows", note: engine.running ? "capture live on \(engine.iface)" : "capture paused — last window",
                                 columns: ["time", "direction", "device", "app", "host", "org", "country", "category", "proto", "port", "bytes", "threat"],
                                 rows: engine.events.map { e in
                                    [iso.string(from: e.time), e.direction, e.device, appDisplayOf(e), bestHost(e), e.org, e.country, e.category, e.proto, String(e.servicePort), String(volumeOf(e).total), e.threat] })
        case .netDevices:
            return ReportSection(title: "Network · devices", columns: ["ip", "name", "class", "os", "type", "vendor", "mac", "flows", "destinations", "first_seen", "last_seen"],
                                 rows: engine.deviceInventory.map { d in
                                    let p = ProfileDB.shared.profile(ip: d.ip)
                                    return [d.ip, displayDeviceTitle(d), d.klass, d.os, d.type, d.vendor, p?.mac ?? "", String(d.flows), String(d.dests),
                                            p.map { iso.string(from: $0.firstSeen) } ?? "", p.map { iso.string(from: $0.lastSeen) } ?? ""] })
        case .netSites:
            let rows = siteRows(scope: .week)
            return ReportSection(title: "Network · sites (7 days)", columns: ["domain", "category", "devices", "visits", "bytes", "first", "last"],
                                 rows: rows.map { [$0.domain, $0.category, $0.devices.map(\.name).joined(separator: "; "), String($0.hits), String($0.bytes), iso.string(from: $0.first), iso.string(from: $0.last)] })
        case .netHistory:
            let remotes = HistoryStore.shared.snapshotRemotes().filter { !$0.r.isPrivate }.sorted { $0.r.bytes > $1.r.bytes }.prefix(200)
            return ReportSection(title: "Network · top talkers", note: "session total \(fmtBytes(HistoryStore.shared.total))",
                                 columns: ["remote", "name", "service", "org", "port", "bytes", "hits", "last"],
                                 rows: remotes.map { [$0.ip, bestHostForIP($0.ip), serviceForIP($0.ip, org: $0.r.org, port: $0.r.port)?.name ?? "", $0.r.org, String($0.r.port), String($0.r.bytes), String($0.r.hits), iso.string(from: $0.r.last)] })
        case .netAlerts:
            var rows = AnomalyStore.shared.items.map { [iso.string(from: $0.time), $0.level, $0.title, $0.detail, $0.deviceIP] }
            rows += engine.alerts.map { [iso.string(from: $0.time), $0.threat.hasPrefix("confirmed") ? "bad" : "review", "Flagged flow", "\($0.device) → \(bestHost($0)) — \($0.threat)", $0.deviceIP] }
            return ReportSection(title: "Network · alerts", columns: ["time", "level", "title", "detail", "device"], rows: rows)
        case .actionsLog:
            return ReportSection(title: "Actions log", columns: ["time", "target", "op", "ok", "message"],
                                 rows: actions.log.map { [iso.string(from: $0.time), $0.target, $0.op, String($0.ok), $0.message] })
        }
    }

    private func sevName(_ s: AttentionItem.Severity) -> String {
        switch s { case .crit: return "critical"; case .warn: return "warning"; case .info: return "info" }
    }
}

// MARK: renderers

enum ReportRenderer {
    static func render(_ r: Report, as f: ExportFormat) throws -> Data {
        switch f {
        case .json: return try json(r)
        case .csv: return Data(csv(r).utf8)
        case .markdown: return Data(markdown(r).utf8)
        case .html: return Data(html(r).utf8)
        case .pdf: return try pdf(r)
        }
    }

    static func json(_ r: Report) throws -> Data {
        let iso = ISO8601DateFormatter()
        var sections: [[String: Any]] = []
        for s in r.sections {
            let rows = s.rows.map { row -> [String: String] in
                var d: [String: String] = [:]
                for (i, c) in s.columns.enumerated() where i < row.count { d[c] = row[i] }
                return d
            }
            sections.append(["title": s.title, "note": s.note, "count": rows.count, "rows": rows])
        }
        let obj: [String: Any] = ["title": r.title, "generated": iso.string(from: r.generated), "source": r.source, "sections": sections]
        return try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    }

    static func csv(_ r: Report) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var out: [String] = []
        for (i, s) in r.sections.enumerated() {
            if r.sections.count > 1 { if i > 0 { out.append("") }; out.append("# \(s.title)") }
            out.append(s.columns.map(q).joined(separator: ","))
            for row in s.rows { out.append(row.map(q).joined(separator: ",")) }
        }
        return out.joined(separator: "\n") + "\n"
    }

    static func markdown(_ r: Report) -> String {
        var out = "# \(r.title)\n\n_Generated \(fmtDate(r.generated)) from \(r.source)_\n\n"
        for s in r.sections {
            out += "## \(s.title)\n\n"
            if !s.note.isEmpty { out += "_\(s.note)_\n\n" }
            if s.rows.isEmpty { out += "_No rows._\n\n"; continue }
            out += "| " + s.columns.joined(separator: " | ") + " |\n"
            out += "|" + s.columns.map { _ in " --- |" }.joined() + "\n"
            for row in s.rows { out += "| " + row.map { $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }.joined(separator: " | ") + " |\n" }
            out += "\n"
        }
        return out
    }

    static func html(_ r: Report) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        var body = "<h1>\(esc(r.title))</h1><p class=meta>Generated \(esc(fmtDate(r.generated))) from \(esc(r.source))</p>"
        for s in r.sections {
            body += "<h2>\(esc(s.title))</h2>"
            if !s.note.isEmpty { body += "<p class=note>\(esc(s.note))</p>" }
            if s.rows.isEmpty { body += "<p class=note>No rows.</p>"; continue }
            body += "<table><thead><tr>" + s.columns.map { "<th>\(esc($0))</th>" }.joined() + "</tr></thead><tbody>"
            for row in s.rows { body += "<tr>" + row.map { "<td>\(esc($0))</td>" }.joined() + "</tr>" }
            body += "</tbody></table>"
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(esc(r.title))</title>
        <style>
        body{font:13px -apple-system,Helvetica,Arial,sans-serif;color:#1d1d1f;margin:32px;max-width:1200px}
        h1{font-size:22px;margin:0 0 4px} h2{font-size:15px;margin:28px 0 8px;border-bottom:1px solid #ddd;padding-bottom:4px}
        .meta,.note{color:#6e6e73;font-size:12px} table{border-collapse:collapse;width:100%;font-size:11.5px}
        th{text-align:left;background:#f2f2f4;padding:5px 7px;border-bottom:1px solid #ccc;white-space:nowrap}
        td{padding:4px 7px;border-bottom:1px solid #eee;vertical-align:top;font-family:ui-monospace,Menlo,monospace;font-size:11px}
        tr:nth-child(even) td{background:#fafafa} @media print{body{margin:12mm} h2{page-break-after:avoid} tr{page-break-inside:avoid}}
        </style></head><body>\(body)</body></html>
        """
    }

    /// Paginated PDF drawn straight into a CGPDFContext: landscape US Letter, one table per
    /// section, header row repeated after each page break, fonts embedded once (the AppKit print
    /// route produced ~260 KB per page).
    static func pdf(_ r: Report) throws -> Data {
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out) else { throw NSError(domain: "hatch", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't create the PDF"]) }
        var box = CGRect(x: 0, y: 0, width: 792, height: 612)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw NSError(domain: "hatch", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't create the PDF context"]) }
        let pdf = PDFWriter(ctx: ctx, box: box, footer: "HatchMap · \(fmtDate(r.generated))")
        pdf.beginPage()
        pdf.text(r.title, font: PDFWriter.font("Helvetica-Bold", 17), color: .black, gap: 6)
        pdf.text("Generated \(fmtDate(r.generated)) from \(r.source)", font: PDFWriter.font("Helvetica", 8.5), color: .gray, gap: 12)
        for s in r.sections {
            pdf.need(40)
            pdf.text(s.title, font: PDFWriter.font("Helvetica-Bold", 11.5), color: .black, gap: 3)
            if !s.note.isEmpty { pdf.text(s.note, font: PDFWriter.font("Helvetica-Oblique", 8), color: .gray, gap: 3) }
            if s.rows.isEmpty { pdf.text("No rows.", font: PDFWriter.font("Helvetica-Oblique", 8), color: .gray, gap: 10); continue }
            pdf.table(columns: s.columns, rows: s.rows)
            pdf.space(12)
        }
        pdf.endPage()
        ctx.closePDF()
        return out as Data
    }

    static func fmtDate(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: d)
    }
}

// MARK: - Sheet

struct ExportSheet: View {
    @ObservedObject var svc: TopologyService
    @ObservedObject var engine: CaptureEngine
    @ObservedObject var insights: InsightStore
    @ObservedObject var actions: ActionService
    @EnvironmentObject private var options: Options
    @Environment(\.dismiss) private var dismiss
    @AppStorage("exportDataset") private var datasetRaw = ExportDataset.everything.rawValue
    @AppStorage("exportFormat") private var formatRaw = ExportFormat.json.rawValue
    @State private var message = ""
    @State private var working = false

    private var dataset: ExportDataset { ExportDataset(rawValue: datasetRaw) ?? .everything }
    private var format: ExportFormat { ExportFormat(rawValue: formatRaw) ?? .json }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export").font(.title2.bold())
            Picker("Data", selection: $datasetRaw) {
                ForEach(ExportDataset.allCases) { d in Text(d.rawValue).tag(d.rawValue) }
            }
            Picker("Format", selection: $formatRaw) {
                ForEach(ExportFormat.allCases) { f in Text(f.rawValue).tag(f.rawValue) }
            }
            .pickerStyle(.segmented)
            HStack {
                Picker("Range", selection: options.bind(\.expRange)) {
                    Text("Everything").tag("all"); Text("Last 24 h").tag("24h"); Text("Last 7 days").tag("7d")
                }
                .pickerStyle(.segmented).frame(width: 300)
                Spacer()
                SettingsLink { Text("Columns…") }.controlSize(.small)
            }
            Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !options.hiddenColumns.isEmpty {
                Text("\(options.hiddenColumns.count) column\(options.hiddenColumns.count == 1 ? "" : "s") hidden via Settings › Export.").font(.caption2).foregroundStyle(.tertiary)
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(message.hasPrefix("Saved") ? .green : .orange) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(working ? "Exporting…" : "Export…") { export() }.keyboardShortcut(.defaultAction).disabled(working)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var hint: String {
        switch format {
        case .json: return "Structured — every section as an array of objects. Best for scripts and re-import."
        case .csv: return dataset == .everything ? "Sections are separated by a “# Section” line so it still opens in Numbers/Excel." : "One table, ready for a spreadsheet or Grafana."
        case .markdown: return "Tables in Markdown — paste into notes, Obsidian or Mattermost."
        case .html: return "A single self-contained page that opens in any browser and prints cleanly."
        case .pdf: return "Landscape US Letter, paginated — the report as a document."
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.canCreateDirectories = true
        let stamp = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"; return f.string(from: Date()) }()
        let base = dataset == .everything ? "hatchmap-export" : "hatchmap-" + dataset.rawValue.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }.replacingOccurrences(of: " ", with: "-")
        panel.nameFieldStringValue = "\(base)-\(stamp).\(format.ext)"
        panel.title = "Export \(dataset.rawValue) as \(format.rawValue)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true
        let report = ReportBuilder(svc: svc, engine: engine, insights: insights, actions: actions).build(dataset)
        do {
            let data = try ReportRenderer.render(report, as: format)
            try data.write(to: url, options: .atomic)
            message = "Saved \(url.lastPathComponent) (\(fmtBytes(data.count)))"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            message = "Export failed: \(error.localizedDescription)"
        }
        working = false
    }
}

// MARK: - Minimal PDF layout engine (Core Graphics + Core Text)

final class PDFWriter {
    let ctx: CGContext
    let box: CGRect
    let margin: CGFloat = 36
    let footer: String
    private var y: CGFloat = 0          // distance from the top of the page
    private var page = 0
    private var open = false

    init(ctx: CGContext, box: CGRect, footer: String) { self.ctx = ctx; self.box = box; self.footer = footer }

    static func font(_ name: String, _ size: CGFloat) -> CTFont { CTFontCreateWithName(name as CFString, size, nil) }
    var width: CGFloat { box.width - 2 * margin }
    private var bottomLimit: CGFloat { box.height - margin - 14 }

    func beginPage() {
        ctx.beginPDFPage(nil); open = true; page += 1; y = margin
    }
    func endPage() {
        guard open else { return }
        draw("\(footer) · page \(page)", at: CGPoint(x: margin, y: box.height - margin + 4), font: PDFWriter.font("Helvetica", 7.5), color: .gray)
        ctx.endPDFPage(); open = false
    }
    func need(_ h: CGFloat) { if y + h > bottomLimit { endPage(); beginPage() } }
    func space(_ h: CGFloat) { y += h }

    func text(_ s: String, font: CTFont, color: NSColor, gap: CGFloat) {
        let h = CTFontGetAscent(font) + CTFontGetDescent(font) + 2
        need(h)
        draw(s, at: CGPoint(x: margin, y: y + CTFontGetAscent(font)), font: font, color: color)
        y += h + gap
    }

    /// Draws a string at a top-left-origin point (converted to PDF's bottom-left space), clipped to `maxWidth`.
    @discardableResult
    private func draw(_ s: String, at p: CGPoint, font: CTFont, color: NSColor, maxWidth: CGFloat = .greatestFiniteMagnitude) -> CGFloat {
        let attr = NSAttributedString(string: s, attributes: [kCTFontAttributeName as NSAttributedString.Key: font, kCTForegroundColorAttributeName as NSAttributedString.Key: color.cgColor])
        var line = CTLineCreateWithAttributedString(attr)
        var w = CTLineGetTypographicBounds(line, nil, nil, nil)
        if w > Double(maxWidth) {
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [kCTFontAttributeName as NSAttributedString.Key: font, kCTForegroundColorAttributeName as NSAttributedString.Key: color.cgColor]))
            line = CTLineCreateTruncatedLine(line, Double(maxWidth), .end, token) ?? line
            w = CTLineGetTypographicBounds(line, nil, nil, nil)
        }
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: p.x, y: box.height - p.y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
        return CGFloat(w)
    }

    func table(columns: [String], rows: [[String]]) {
        let cell = PDFWriter.font("Menlo", 7)
        let head = PDFWriter.font("Helvetica-Bold", 7.5)
        let charW: CGFloat = 4.3
        // Natural widths from content (capped), then fit to the page.
        var nat = columns.map { CGFloat($0.count) * 4.6 + 8 }
        for row in rows.prefix(400) {
            for (i, c) in row.enumerated() where i < nat.count { nat[i] = max(nat[i], min(CGFloat(c.count) * charW + 8, 230)) }
        }
        var widths = nat
        // Fit to the page: scale down, then take any remaining overflow off the widest columns
        // so the sum never exceeds the printable width (a clipped last column reads as a bug).
        if widths.reduce(0, +) > width {
            let total = widths.reduce(0, +)
            widths = widths.map { max(34, $0 * width / total) }
            var over = widths.reduce(0, +) - width
            while over > 0.5, let i = widths.indices.max(by: { widths[$0] < widths[$1] }), widths[i] > 60 {
                let cut = min(over, widths[i] - 60)
                widths[i] -= cut; over -= cut
            }
        }
        let rowH: CGFloat = 12
        func header() {
            need(rowH * 2)
            ctx.setFillColor(NSColor(white: 0.92, alpha: 1).cgColor)
            ctx.fill(CGRect(x: margin, y: box.height - y - rowH, width: min(widths.reduce(0, +), width), height: rowH))
            var x = margin
            for (i, c) in columns.enumerated() {
                draw(c, at: CGPoint(x: x + 3, y: y + 9), font: head, color: .black, maxWidth: widths[i] - 6)
                x += widths[i]
            }
            y += rowH
        }
        header()
        for (ri, row) in rows.enumerated() {
            if y + rowH > bottomLimit { endPage(); beginPage(); header() }
            if ri % 2 == 1 {
                ctx.setFillColor(NSColor(white: 0.975, alpha: 1).cgColor)
                ctx.fill(CGRect(x: margin, y: box.height - y - rowH, width: min(widths.reduce(0, +), width), height: rowH))
            }
            var x = margin
            for (i, c) in row.enumerated() where i < widths.count {
                draw(c.replacingOccurrences(of: "\n", with: " "), at: CGPoint(x: x + 3, y: y + 8.5), font: cell, color: NSColor(white: 0.12, alpha: 1), maxWidth: widths[i] - 6)
                x += widths[i]
            }
            ctx.setStrokeColor(NSColor(white: 0.85, alpha: 1).cgColor)
            ctx.setLineWidth(0.3)
            ctx.move(to: CGPoint(x: margin, y: box.height - y - rowH)); ctx.addLine(to: CGPoint(x: margin + min(widths.reduce(0, +), width), y: box.height - y - rowH)); ctx.strokePath()
            y += rowH
        }
    }
}
