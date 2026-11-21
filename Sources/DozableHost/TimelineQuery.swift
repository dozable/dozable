import Foundation

// 747: the timeline's answers from `timeline.sqlite` — the catalogue, a query (rows by scope and depth, the parsed
// search compiled to SQL, filters, bins in the owner's time zone, rollups, pages, retention) and the live feed's batches
// (everything with a `rev` past the client's). The same in the daemon and in-process (a read never writes). The
// contract's reference engine is the model; `TimelineQueryTests` holds this to the Swift matcher on every vector.

/// Bins in a time zone (the contract's §3): a 1d bin starts at local midnight, a 1h bin on the local hour (the UTC hour
/// unless the offset isn't whole hours), a 1m bin on the UTC minute.
public enum TimelineTime {
    static let minute: Int64 = 60_000, hour: Int64 = 3_600_000, day: Int64 = 86_400_000

    public static func offset(_ tz: TimeZone?, _ t: Int64) -> Int64 {
        guard let tz else { return 0 }
        return Int64(tz.secondsFromGMT(for: Date(timeIntervalSince1970: Double(t) / 1000))) * 1000
    }
    static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 { a >= 0 ? a / b : -((-a + b - 1) / b) }

    public static func start(_ t: Int64, _ bin: TimelineBin, _ tz: TimeZone?) -> Int64 {
        switch bin {
        case .m1: return floorDiv(t, minute) * minute
        case .h1:
            let off = offset(tz, t)
            return off % hour == 0 ? floorDiv(t, hour) * hour : floorDiv(t + off, hour) * hour - off
        case .d1:
            let off = offset(tz, t)
            let d = floorDiv(t + off, day) * day
            var s = d - offset(tz, d - off)
            if s > t { s = d - day - offset(tz, d - day - off) } else if next(s, tz) <= t { s = next(s, tz) }
            return s
        }
    }
    public static func next(_ s: Int64, _ tz: TimeZone?) -> Int64 {
        let off = offset(tz, s), d = floorDiv(s + off, day) * day + day
        return d - offset(tz, d - off)
    }
    /// The zone a query names (nil: UTC); an unknown one is UTC with a warning.
    public static func zone(_ name: String?) -> (TimeZone?, String?) {
        guard let name, !name.isEmpty, name != "UTC" else { return (nil, nil) }
        if let z = TimeZone(identifier: name) { return (z, nil) }
        return (nil, "the time zone \(name) is not known here: bins are in UTC")
    }
}

public final class TimelineQueryEngine: @unchecked Sendable {
    public let store: TimelineStore
    /// This host's segment (`host:this%20Mac`).
    public let host: String
    let now: Int64
    /// How far a first indexing has come (nil: done) — said as a warning.
    let indexing: Int?
    let retention: (String) -> (retention: TimelineRetention, setBy: String)

    public init(store: TimelineStore, host: String, now: Int64, indexing: Int? = nil,
                retention: ((String) -> (retention: TimelineRetention, setBy: String))? = nil) {
        self.store = store; self.host = host; self.now = now; self.indexing = indexing
        if let retention { self.retention = retention } else {
            let all = TimelineRetentionSettings.all()          // read once per answer
            self.retention = { all[$0] ?? TimelineRetentionSettings.effective($0) }
        }
    }

    var db: SQLiteDB { store.db }

    // MARK: the catalogue

    public func catalog() throws -> TimelineCatalog {
        TimelineCatalog(hosts: [TimelineScope.name(host)], sources: TimelineSources.all, retention: try effective(TimelineSources.all.map(\.name)),
                        names: try names(), now: now)
    }

    func names() throws -> [TimelineScopeName] {
        var aliases: [String: [String]] = [:]
        for r in try db.rows("SELECT scope, alias_of FROM names ORDER BY at") {
            if let s = r[0].text, let a = r[1].text { aliases[s, default: []].append(TimelineStore.full(a, host: host)) }
        }
        var out: [TimelineScopeName] = []
        var seen: Set<String> = []
        for r in try db.rows("SELECT scope, label, space FROM scopes WHERE space = 1 OR label != '' ORDER BY scope") {
            guard let s = r[0].text, let label = r[1].text else { continue }
            let named = label != TimelineScope.name(s) || r[2].int == 1 || aliases[s] != nil
            guard named else { continue }
            seen.insert(s)
            out.append(TimelineScopeName(scope: TimelineStore.full(s, host: host), label: label, space: r[2].int == 1, aliases: aliases[s]))
        }
        for (s, a) in aliases where !seen.contains(s) {
            out.append(TimelineScopeName(scope: TimelineStore.full(s, host: host), label: TimelineScope.name(s), aliases: a))
        }
        return out.sorted { $0.scope < $1.scope }
    }

    /// The cut points retention has reached, per source.
    func kept() throws -> [String: TimelineKeptFrom] {
        var out: [String: TimelineKeptFrom] = [:]
        for r in try db.rows("SELECT source, events, m1, h1, d1 FROM kept") {
            guard let s = r[0].text else { continue }
            out[s] = TimelineKeptFrom(events: r[1].int, m1: r[2].int, h1: r[3].int, d1: r[4].int)
        }
        return out
    }

    public func effective(_ sources: [String]) throws -> [TimelineEffectiveRetention] {
        let cuts = try kept()
        var earliestEvent: [String: Int64] = [:]
        for r in try db.rows("SELECT source, MIN(t) FROM events GROUP BY source") { if let s = r[0].text, let t = r[1].int { earliestEvent[s] = t } }
        var earliestBin: [String: [String: Int64]] = [:]
        for r in try db.rows("SELECT series, bin, MIN(t) FROM rollups GROUP BY series, bin") {
            guard let series = r[0].text, let bin = r[1].text, let t = r[2].int, let src = TimelineSources.seriesSource[series] else { continue }
            earliestBin[src, default: [:]][bin] = min(earliestBin[src]?[bin] ?? .max, t)
        }
        for r in try db.rows("SELECT source, bin, MIN(t) FROM ebins GROUP BY source, bin") {
            guard let src = r[0].text, let bin = r[1].text, let t = r[2].int else { continue }
            earliestBin[src, default: [:]][bin] = min(earliestBin[src]?[bin] ?? .max, t)
        }
        return Array(Set(sources)).sorted().compactMap { name in
            guard TimelineSources.source(name) != nil else { return nil }
            let (r, by) = retention(name)
            let c = cuts[name]
            let ev = earliestEvent[name].map { max($0, c?.events ?? $0) }
            var kf = TimelineKeptFrom(events: ev)
            let anyBin = [earliestBin[name]?["1m"], earliestBin[name]?["1h"], earliestBin[name]?["1d"], earliestEvent[name]].compactMap { $0 }.min()
            if let first = anyBin {
                kf.m1 = max(first, c?.m1 ?? first)
                kf.h1 = max(first, c?.h1 ?? first)
                kf.d1 = max(first, c?.d1 ?? first)
            }
            return TimelineEffectiveRetention(source: name, retention: r, setBy: by, keptFrom: kf)
        }
    }

    // MARK: the search, as SQL

    struct Compiled { var sql: String; var args: [SQLValue] }

    /// `scope` and everything under it (host-relative; "" is everything).
    static func scopeCond(_ rel: String, column: String = "scope") -> Compiled {
        if rel.isEmpty { return Compiled(sql: "1", args: []) }
        return Compiled(sql: "(\(column) = ? OR (\(column) >= ? AND \(column) < ?))", args: [.text(rel), .text(rel + "/"), .text(rel + "0")])
    }

    /// The full scope as SQL text (`host:x/rel`), between slashes.
    var slashed: Compiled { Compiled(sql: "('/' || ? || CASE WHEN scope = '' THEN '' ELSE '/' || scope END || '/')", args: [.text(host)]) }

    static func likeEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    func compile(_ m: TimelineMatch) -> Compiled {
        switch m {
        case .text(let v):
            let low = v.lowercased()
            guard !low.isEmpty else { return Compiled(sql: "1", args: []) }
            if low.unicodeScalars.count >= 3 {
                let phrase = "\"" + low.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                return Compiled(sql: "(rowid IN (SELECT rowid FROM events_fts WHERE events_fts MATCH ?) AND instr(hay, ?) > 0)", args: [.text(phrase), .text(low)])
            }
            return Compiled(sql: "instr(hay, ?) > 0", args: [.text(low)])
        case .kind(let v, let p), .source(let v, let p):
            let col: String = { if case .kind = m { return "kind" }; return "source" }()
            if p { return Compiled(sql: "substr(\(col), 1, ?) = ?", args: [.int(Int64(v.count)), .text(v)]) }
            return Compiled(sql: "\(col) = ?", args: [.text(v)])
        case .severity(let op, let v):
            let o = ["ge": ">=", "gt": ">", "le": "<=", "lt": "<"][op] ?? "="
            return Compiled(sql: "sev \(o) ?", args: [.int(Int64(v.rank))])
        case .scope(let v, let top):
            if top {
                if v.isEmpty { return Compiled(sql: "1", args: []) }
                guard let rel = TimelineStore.relative(v, host: host) else { return Compiled(sql: "0", args: []) }
                return Self.scopeCond(rel)
            }
            let s = slashed
            return Compiled(sql: "instr(\(s.sql), ?) > 0", args: s.args + [.text("/" + v + "/")])
        case .link(let l, let v):
            guard l == "run" else { return Compiled(sql: "l_\(l) = ?", args: [.text(v)]) }
            let slash = v.lastIndex(of: "/")
            let id = slash.map { String(v[v.index(after: $0)...]) } ?? v
            let ws = slash.flatMap { $0 > v.startIndex ? String(v[..<$0]) : nil }
            let s = slashed
            let inScope = "/" + (ws.map { "workspace:" + $0 + "/" } ?? "") + "run:" + id + "/"
            if ws != nil {
                return Compiled(sql: "(l_run = ? OR instr(\(s.sql), ?) > 0)", args: [.text(v)] + s.args + [.text(inScope)])
            }
            return Compiled(sql: "(l_run = ? OR l_run LIKE ? ESCAPE '\\' OR instr(\(s.sql), ?) > 0)",
                            args: [.text(v), .text("%/" + Self.likeEscape(id))] + s.args + [.text(inScope)])
        case .attr(let k, let v):
            func val(_ col: String) -> String {
                "(CASE json_type(\(col), '$.\(k)') WHEN 'true' THEN 'true' WHEN 'false' THEN 'false' WHEN 'null' THEN NULL ELSE CAST(json_extract(\(col), '$.\(k)') AS TEXT) END)"
            }
            return Compiled(sql: "(lower(\(val("attrs"))) = ? OR (sattrs IS NOT NULL AND lower(\(val("sattrs"))) = ?))", args: [.text(v.lowercased()), .text(v.lowercased())])
        }
    }

    func compile(_ ast: TimelineSearchAst?) -> Compiled {
        guard let all = ast?.all, !all.isEmpty else { return Compiled(sql: "1", args: []) }
        var sql: [String] = [], args: [SQLValue] = []
        for term in all {
            let parts = term.any.map(compile)
            let any = "(" + parts.map(\.sql).joined(separator: " OR ") + ")"
            sql.append(term.not == true ? "NOT " + any : any)
            args += parts.flatMap(\.args)
        }
        return Compiled(sql: sql.joined(separator: " AND "), args: args)
    }

    /// What a query keeps of an event, but its time: its scope, the filters, the search, each source's retention.
    func predicate(_ q: TimelineQuery, rel: String) -> Compiled {
        var sql = [Self.scopeCond(rel).sql], args = Self.scopeCond(rel).args
        let f = q.filters ?? TimelineFilters()
        func inList(_ col: String, _ vs: [String]?) {
            guard let vs, !vs.isEmpty else { return }
            sql.append("\(col) IN (" + vs.map { _ in "?" }.joined(separator: ",") + ")")
            args += vs.map { .text($0) }
        }
        inList("source", f.source)
        inList("kind", f.kind)
        if let s = f.severity, !s.isEmpty {
            sql.append("sev IN (" + s.map { String($0.rank) }.joined(separator: ",") + ")")
        }
        if let sc = f.scope, !sc.isEmpty {
            let parts = sc.map { full -> Compiled in
                if full.isEmpty { return Compiled(sql: "1", args: []) }
                guard let r = TimelineStore.relative(full, host: host) else { return Compiled(sql: "0", args: []) }
                return Self.scopeCond(r)
            }
            sql.append("(" + parts.map(\.sql).joined(separator: " OR ") + ")")
            args += parts.flatMap(\.args)
        }
        for s in TimelineSources.kept {
            if let d = retention(s.name).retention.events {
                sql.append("NOT (source = ? AND t < ?)")
                args += [.text(s.name), .int(now - Int64(d) * 86_400_000)]
            }
        }
        let w = compile(q.where)
        sql.append(w.sql); args += w.args
        return Compiled(sql: sql.joined(separator: " AND "), args: args)
    }

    /// In [from, to), or a span that began before and lasts into it (an open one lasts to now).
    static func inRange(_ from: Int64, _ to: Int64, now: Int64) -> Compiled {
        Compiled(sql: "((t >= ? AND t < ?) OR (t < ? AND ((dur IS NOT NULL AND open = 0 AND t + dur > ?) OR (open = 1 AND ? > ?))))",
                 args: [.int(from), .int(to), .int(from), .int(from), .int(now), .int(from)])
    }

    // MARK: rows

    struct Rows {
        var level: Int
        var base: Int
        var rows: [String: TimelineRow] = [:]
        /// A (relative) scope's row's full scope (nil: not under the query).
        var cache: [String: String?] = [:]
    }

    func rowsOf(_ q: TimelineQuery, rel: String?) throws -> Rows {
        let base = TimelineScope.level(q.scope), level = base + q.depth
        var r = Rows(level: level, base: base)
        guard let rel else { return r }
        // Every known scope at the rows' level is a row, with events or not.
        let labels = try labelMap()
        let childCount = try childCounts()
        if level == 0 {
            r.rows[""] = TimelineRow(scope: "", label: "all hosts", kind: "fleet", depth: 0, children: 1, count: 0)
        } else if level == 1 {
            r.rows[host] = TimelineRow(scope: host, label: TimelineScope.name(host), kind: "host", depth: 1 - base, children: childCount[""] ?? 0, count: 0)
        } else {
            for row in try db.rows("SELECT scope FROM scopes WHERE length(scope) - length(replace(scope, '/', '')) = ?", [.int(Int64(level - 2))]) {
                guard let s = row[0].text, rel.isEmpty || TimelineScope.within(s, rel) else { continue }
                let full = TimelineStore.full(s, host: host)
                let l = labels[s]
                r.rows[full] = TimelineRow(scope: full, label: l?.0 ?? TimelineScope.name(s), kind: TimelineScope.kind(s), space: l?.1,
                                           depth: q.depth, children: childCount[s] ?? 0, count: 0)
            }
        }
        _ = labels
        return r
    }

    var labelsCache: [String: (String, Bool)]?
    func labelMap() throws -> [String: (String, Bool)] {
        if let l = labelsCache { return l }
        var out: [String: (String, Bool)] = [:]
        for r in try db.rows("SELECT scope, label, space FROM scopes") { if let s = r[0].text { out[s] = (r[1].text ?? "", r[2].int == 1) } }
        labelsCache = out
        return out
    }
    var childCache: [String: Int]?
    func childCounts() throws -> [String: Int] {
        if let c = childCache { return c }
        var out: [String: Int] = [:]
        for r in try db.rows("SELECT parent, COUNT(*) FROM scopes GROUP BY parent") { if let p = r[0].text { out[p] = Int(r[1].int ?? 0) } }
        childCache = out
        return out
    }

    /// The row an event's (relative) scope counts on, adding an own row when it is shallower than the rows.
    func row(_ relScope: String, _ r: inout Rows, depth: Int) throws -> String? {
        if let hit = r.cache[relScope] { return hit }
        let full = TimelineStore.full(relScope, host: host)
        let lvl = TimelineScope.level(full)
        let out: String
        if r.level == 0 { out = "" }
        else if lvl >= r.level { out = TimelineScope.prefix(full, level: r.level) }
        else { out = full }
        if r.rows[out] == nil {
            let rel = TimelineStore.relative(out, host: host) ?? ""
            let l = try labelMap()[rel]
            let d = TimelineScope.level(out) - r.base
            r.rows[out] = TimelineRow(scope: out, label: out == host ? TimelineScope.name(host) : (l?.0 ?? TimelineScope.name(out)),
                                      kind: TimelineScope.kind(out), space: l?.1, depth: d, own: d < depth, children: try childCounts()[rel] ?? 0,
                                      count: 0)
        }
        r.cache[relScope] = out
        return out
    }

    // MARK: query

    static let defaultLimit = 2000, maximumLimit = 10_000

    func event(_ r: [SQLValue], sensitive: Bool) -> TimelineEvent {
        // id, source, t, dur, open, scope, kind, sev, summary, attrs, sattrs, l_run, l_ask, l_msg, l_session, l_decision
        var attrs = (try? HostWire.decoder.decode([String: TimelineAttr].self, from: Data((r[9].text ?? "{}").utf8))) ?? [:]
        if sensitive, let s = r[10].text, let sa = try? HostWire.decoder.decode([String: TimelineAttr].self, from: Data(s.utf8)) {
            for (k, v) in sa { attrs[k] = v }
        }
        return TimelineEvent(id: r[0].text ?? "", t: r[2].int ?? 0, dur: r[3].int, open: r[4].int == 1, scope: TimelineStore.full(r[5].text ?? "", host: host),
                             source: r[1].text ?? "", kind: r[6].text ?? "", severity: TimelineSeverity.allCases[min(4, max(0, Int(r[7].int ?? 1)))],
                             summary: r[8].text ?? "", attrs: attrs,
                             links: TimelineLinks(run: r[11].text, ask: r[12].text, msg: r[13].text, session: r[14].text, decision: r[15].text))
    }
    static let columns = "id, source, t, dur, open, scope, kind, sev, summary, attrs, sattrs, l_run, l_ask, l_msg, l_session, l_decision"

    /// Sensitive attrs are returned only when the search names one (`attr.KEY:`).
    static func asksSensitive(_ q: TimelineQuery) -> Bool {
        q.where?.all.contains { $0.any.contains { if case .attr = $0 { return true }; return false } } == true
    }

    public func query(_ q: TimelineQuery) throws -> TimelineResult {
        guard TimelineScope.isScope(q.scope) else { throw HostError(.invalid, "not a scope path: \(q.scope)") }
        guard q.depth >= 0, q.depth <= 6 else { throw HostError(.invalid, "depth is 0–6") }
        let rel: String? = q.scope.isEmpty ? "" : TimelineStore.relative(q.scope, host: host)
        var warnings: [String] = []
        if let p = indexing { warnings.append("indexing the history: \(p)% done — what is not indexed yet is missing") }
        let (tz, tzWarning) = TimelineTime.zone(q.tz)
        if let tzWarning { warnings.append(tzWarning) }
        var rows = try rowsOf(q, rel: rel)
        guard let rel else {
            return TimelineResult(rows: [], events: q.bin == nil ? [] : nil, bins: q.bin == nil ? nil : [], spans: q.bin == nil ? nil : [],
                                  metrics: [], total: 0, retention: [], warnings: warnings)
        }
        let p = predicate(q, rel: rel)
        let range = Self.inRange(q.from, q.to, now: now)
        let whereSQL = p.sql + " AND " + range.sql
        let args = p.args + range.args
        let sensitive = Self.asksSensitive(q)
        // Rows: counts by scope, folded.
        var sources: Set<String> = []
        for r in try db.rows("SELECT scope, source, COUNT(*), MIN(t), MAX(t) FROM events WHERE \(whereSQL) GROUP BY scope, source", args) {
            guard let s = r[0].text, let key = try row(s, &rows, depth: q.depth) else { continue }
            let n = r[2].int ?? 0
            if var row = rows.rows[key] {
                row.count += n
                if let a = r[3].int { row.first = min(row.first ?? a, a) }
                if let b = r[4].int { row.last = max(row.last ?? b, b) }
                rows.rows[key] = row
            }
            if let src = r[1].text { sources.insert(src) }
        }
        let total = rows.rows.values.reduce(0) { $0 + $1.count }
        let metrics = try metricsFor(q, rel: rel, tz: tz, rows: &rows, sources: &sources, warnings: &warnings)
        let sortedRows = rows.rows.values.sorted { $0.scope < $1.scope }
        if let bin = q.bin {
            let (bins, spans) = try binned(q, bin: bin, tz: tz, whereSQL: whereSQL, args: args, rows: &rows, sensitive: sensitive,
                                           pred: p, sources: &sources, warnings: &warnings)
            return TimelineResult(rows: rows.rows.values.sorted { $0.scope < $1.scope }, bins: bins, spans: spans, metrics: metrics, total: total,
                                  retention: try effective(Array(sources)), warnings: warnings)
        }
        let limit = min(Self.maximumLimit, max(1, q.limit ?? Self.defaultLimit))
        var pageSQL = "SELECT \(Self.columns) FROM events WHERE \(whereSQL)"
        var pageArgs = args
        if let c = q.cursor {
            guard let cur = Self.decodeCursor(c) else { throw HostError(.invalid, "not a cursor of this host") }
            pageSQL += " AND (t > ? OR (t = ? AND id > ?))"
            pageArgs += [.int(cur.t), .int(cur.t), .text(cur.id)]
        }
        pageSQL += " ORDER BY t, id LIMIT ?"
        pageArgs.append(.int(Int64(limit + 1)))
        var page = try db.rows(pageSQL, pageArgs).map { event($0, sensitive: sensitive) }
        let more = page.count > limit
        if more { page.removeLast() }
        return TimelineResult(rows: sortedRows, events: page, metrics: metrics, total: total, retention: try effective(Array(sources)),
                              warnings: warnings, next: more ? page.last.map { Self.encodeCursor($0) } : nil)
    }

    static func encodeCursor(_ e: TimelineEvent) -> String {
        Data(#"{"t":\#(e.t),"id":\#(String(decoding: (try? JSONEncoder().encode(e.id)) ?? Data(), as: UTF8.self))}"#.utf8).base64EncodedString()
    }
    static func decodeCursor(_ c: String) -> (t: Int64, id: String)? {
        struct C: Decodable { var t: Int64; var id: String }
        guard let d = Data(base64Encoded: c), let v = try? JSONDecoder().decode(C.self, from: d) else { return nil }
        return (v.t, v.id)
    }

    // MARK: bins

    func binned(_ q: TimelineQuery, bin: TimelineBin, tz: TimeZone?, whereSQL: String, args: [SQLValue], rows: inout Rows, sensitive: Bool,
                pred: Compiled, sources: inout Set<String>, warnings: inout [String]) throws -> ([TimelineEventBin], [TimelineEvent]) {
        struct Acc { var count: Int64 = 0; var sev = [Int64](repeating: 0, count: 5); var kinds: [String: Int64] = [:]; var truncated = false }
        var acc: [String: Acc] = [:]
        // An event counts in the bin of its t: grouped by quarter hour (every zone's offset is whole quarters), then placed.
        let width: Int64 = bin == .m1 ? 60_000 : 900_000
        // A prune under way: what its counts already hold is not counted again from the events not yet deleted.
        let cutsNow = try kept()
        var already = "", alreadyArgs: [SQLValue] = []
        for (src, c) in cutsNow { if let ce = c.events { already += " AND NOT (source = ? AND t < ? AND open = 0)"; alreadyArgs += [.text(src), .int(ce)] } }
        for r in try db.rows("""
            SELECT scope, (t / ?) AS q, kind, sev, COUNT(*) FROM events WHERE \(whereSQL) AND t >= ?\(already) GROUP BY scope, q, kind, sev
            """, [.int(width)] + args + [.int(q.from)] + alreadyArgs) {
            guard let s = r[0].text, let key = try row(s, &rows, depth: q.depth) else { continue }
            let t = TimelineTime.start((r[1].int ?? 0) * width, bin, tz)
            let k = "\(key)\u{0}\(t)"
            var a = acc[k] ?? Acc()
            let n = r[4].int ?? 0
            a.count += n
            a.sev[min(4, max(0, Int(r[3].int ?? 1)))] += n
            a.kinds[r[2].text ?? "", default: 0] += n
            acc[k] = a
        }
        // Before a source's single events were pruned: its event bins (counts by kind and severity) — only for a query
        // whose search and filters bins can answer (scope, source, severity).
        let f = q.filters ?? TimelineFilters()
        let plain = (q.where?.all.isEmpty ?? true) && (f.kind ?? []).isEmpty
        let cuts = try kept()
        var fromBins = false
        for (src, cut) in cuts {
            guard let ce = cut.events, ce > q.from else { continue }
            if let fs = f.source, !fs.isEmpty, !fs.contains(src) { continue }
            guard plain else { warnings.append("before \(Self.iso(ce)) only counts of \(src) are kept: a search does not reach them"); continue }
            // The finest level held that nests in the query's bin.
            for level in TimelineBin.allCases where level.milliseconds <= bin.milliseconds {
                let rowsAt = try db.rows("""
                    SELECT scope, t, count, sev0, sev1, sev2, sev3, sev4, kinds, kinds_truncated FROM ebins
                    WHERE source = ? AND bin = ? AND t >= ? AND t < ? AND \(Self.scopeCond(TimelineStore.relative(q.scope, host: host) ?? "").sql)
                    """, [.text(src), .text(level.rawValue), .int(q.from), .int(min(q.to, ce))] + Self.scopeCond(TimelineStore.relative(q.scope, host: host) ?? "").args)
                guard !rowsAt.isEmpty else { continue }
                fromBins = true
                sources.insert(src)
                for r in rowsAt {
                    guard let s = r[0].text, let key = try row(s, &rows, depth: q.depth) else { continue }
                    let sev = (3...7).map { r[$0].int ?? 0 }
                    if let fsev = f.severity, !fsev.isEmpty, !fsev.contains(where: { sev[$0.rank] > 0 }) { continue }
                    let t = TimelineTime.start(r[1].int ?? 0, bin, tz)
                    let k = "\(key)\u{0}\(t)"
                    var a = acc[k] ?? Acc()
                    a.count += r[2].int ?? 0
                    for i in 0..<5 { a.sev[i] += sev[i] }
                    for (kk, v) in (try? JSONDecoder().decode([String: Int64].self, from: Data((r[8].text ?? "{}").utf8))) ?? [:] { a.kinds[kk, default: 0] += v }
                    if r[9].int == 1 { a.truncated = true }
                    acc[k] = a
                    rows.rows[key]?.count += r[2].int ?? 0
                }
                break
            }
        }
        if fromBins { warnings.append("some bins are made of counts kept after their single events were removed") }
        var bins: [TimelineEventBin] = []
        for (k, a) in acc {
            let parts = k.split(separator: "\u{0}", omittingEmptySubsequences: false)
            var sev: [String: Int64] = [:]
            for (i, s) in TimelineSeverity.allCases.enumerated() where a.sev[i] > 0 { sev[s.rawValue] = a.sev[i] }
            var kinds = a.kinds
            var truncated = a.truncated
            if kinds.count > 20 {
                kinds = Dictionary(uniqueKeysWithValues: kinds.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(20).map { ($0.key, $0.value) })
                truncated = true
            }
            bins.append(TimelineEventBin(scope: String(parts[0]), t: Int64(parts[1]) ?? 0, bin: bin, count: a.count, severity: sev, kinds: kinds,
                                         kindsTruncated: truncated ? true : nil))
        }
        bins.sort { $0.t != $1.t ? $0.t < $1.t : $0.scope < $1.scope }
        // Spans at least one bin long, and the open ones, so they still draw zoomed out.
        let spans = try db.rows("""
            SELECT \(Self.columns) FROM events WHERE \(whereSQL) AND (open = 1 OR (dur IS NOT NULL AND dur >= ?)) ORDER BY t, id LIMIT 5000
            """, args + [.int(bin.milliseconds)]).map { event($0, sensitive: sensitive) }
        return (bins, spans)
    }

    static func iso(_ t: Int64) -> String { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(t) / 1000)) }

    // MARK: metrics

    func metricsFor(_ q: TimelineQuery, rel: String, tz: TimeZone?, rows: inout Rows, sources: inout Set<String>, warnings: inout [String]) throws -> [TimelineMetric] {
        let want = q.series.flatMap { $0.isEmpty ? nil : Set($0) }
        let sc = Self.scopeCond(rel)
        let cuts = try kept()
        struct Acc { var min = Double.infinity; var max = -Double.infinity; var sum = 0.0; var count: Int64 = 0 }
        var acc: [String: Acc] = [:]
        func add(_ series: String, _ scope: String, _ t: Int64, _ mn: Double, _ mx: Double, _ sum: Double, _ n: Int64) throws {
            guard let key = try row(scope, &rows, depth: q.depth) else { return }
            let k = "\(series)\u{0}\(key)\u{0}\(t)"
            var a = acc[k] ?? Acc()
            a.min = Swift.min(a.min, mn); a.max = Swift.max(a.max, mx); a.sum += sum; a.count += n
            acc[k] = a
        }
        let mac = TimeZone(identifier: store.meta("tz") ?? "") ?? TimeZone.current
        var seriesFilter = "", sArgs: [SQLValue] = []
        if let want { seriesFilter = " AND series IN (" + want.map { _ in "?" }.joined(separator: ",") + ")"; sArgs = want.map { .text($0) } }
        let fromStart = q.bin.map { TimelineTime.start(q.from, $0, tz) } ?? q.from
        // Minutes: where they are kept (grouped by quarter hour for a coarser bin, then placed in the query's zone).
        let width: Int64 = q.bin == nil || q.bin == .m1 ? 60_000 : 900_000
        for r in try db.rows("""
            SELECT series, scope, (t / ?) AS b, MIN(min), MAX(max), SUM(sum), SUM(count) FROM rollups
            WHERE bin = '1m' AND t >= ? AND t < ? AND \(sc.sql)\(seriesFilter) GROUP BY series, scope, b
            """, [.int(width), .int(fromStart), .int(q.to)] + sc.args + sArgs) {
            guard let series = r[0].text, let scope = r[1].text, let src = TimelineSources.seriesSource[series] else { continue }
            let t0 = (r[2].int ?? 0) * width
            if let d = retention(src).retention.m1, t0 < now - Int64(d) * 86_400_000 { continue }
            sources.insert(src)
            let t = q.bin.map { TimelineTime.start(t0, $0, tz) } ?? t0
            try add(series, scope, t, r[3].real ?? 0, r[4].real ?? 0, r[5].real ?? 0, r[6].int ?? 0)
        }
        // Before the minutes were pruned: the stored hours, then days (in UTC hours and the Mac's zone).
        if let bin = q.bin, bin != .m1 {
            var sameZone = (tz?.identifier ?? "UTC") == mac.identifier || tz == nil && mac.secondsFromGMT() == 0
            if bin == .h1, (tz.map { $0.secondsFromGMT() % 3600 == 0 } ?? true) { sameZone = true }
            for level in [TimelineBin.h1, .d1] where level.milliseconds <= bin.milliseconds {
                for (src, cut) in cuts {
                    let upTo = level == .h1 ? cut.m1 : cut.h1
                    guard let upTo, upTo > q.from else { continue }
                    let series = TimelineSources.source(src)?.series.map(\.name) ?? []
                    guard !series.isEmpty else { continue }
                    if !sameZone { warnings.append("before \(Self.iso(upTo)) \(src) is kept by \(level == .h1 ? "hour" : "day") in this Mac's zone only"); continue }
                    for r in try db.rows("""
                        SELECT series, scope, t, min, max, sum, count FROM rollups WHERE bin = ? AND t >= ? AND t < ? AND \(sc.sql)
                          AND series IN (\(series.map { _ in "?" }.joined(separator: ",")))\(seriesFilter)
                        """, [.text(level.rawValue), .int(fromStart), .int(min(q.to, upTo))] + sc.args + series.map { .text($0) } + sArgs) {
                        guard let s = r[0].text, let scope = r[1].text else { continue }
                        sources.insert(src)
                        try add(s, scope, TimelineTime.start(r[2].int ?? 0, bin, tz), r[3].real ?? 0, r[4].real ?? 0, r[5].real ?? 0, r[6].int ?? 0)
                    }
                }
            }
        }
        var out: [TimelineMetric] = []
        for (k, a) in acc {
            let p = k.split(separator: "\u{0}", omittingEmptySubsequences: false).map(String.init)
            let t = Int64(p[2]) ?? 0
            if let bin = q.bin {
                out.append(.rollup(series: p[0], scope: p[1], t: t, bin: bin, min: a.min, max: a.max, sum: a.sum, count: a.count))
            } else {
                let gauge = TimelineSources.seriesType[p[0]] == "gauge"
                out.append(.point(series: p[0], scope: p[1], t: t, value: a.count == 1 || !gauge ? a.sum : a.sum / Double(a.count)))
            }
        }
        out.sort { $0.t != $1.t ? $0.t < $1.t : $0.series != $1.series ? $0.series < $1.series : $0.scope < $1.scope }
        return out
    }

    // MARK: live

    /// What changed past `rev` that the query keeps: events (a replaced one by its id) and minute points, with the new
    /// resume token. nil: `rev` is older than what retention has removed since — the client queries afresh.
    public func batch(_ q: TimelineQuery, after rev: Int64) throws -> TimelineBatch? {
        let pruned = ((try? db.scalar("SELECT MAX(pruned_rev) FROM kept"))?.int) ?? 0
        if rev < pruned { return nil }
        guard TimelineScope.isScope(q.scope), let rel = q.scope.isEmpty ? "" : TimelineStore.relative(q.scope, host: host) else {
            return TimelineBatch(events: [], metrics: [], now: now, resume: String(store.currentRev))
        }
        let top = ((try? db.scalar("SELECT MAX(r) FROM (SELECT MAX(rev) AS r FROM events UNION ALL SELECT MAX(rev) FROM rollups)"))?.int) ?? rev
        let p = predicate(q, rel: rel)
        let sensitive = Self.asksSensitive(q)
        var rows = try rowsOf(q, rel: rel)
        let known = Set(rows.rows.keys)
        var events: [TimelineEvent] = []
        for r in try db.rows("SELECT \(Self.columns) FROM events WHERE rev > ? AND rev <= ? AND \(p.sql) ORDER BY t, id LIMIT 10000",
                             [.int(rev), .int(top)] + p.args) {
            let e = event(r, sensitive: sensitive)
            _ = try row(r[5].text ?? "", &rows, depth: q.depth)
            events.append(e)
        }
        var metrics: [TimelineMetric] = []
        let sc = Self.scopeCond(rel)
        let want = q.series.flatMap { $0.isEmpty ? nil : Set($0) }
        for r in try db.rows("SELECT series, scope, t, sum, count FROM rollups WHERE bin = '1m' AND rev > ? AND rev <= ? AND \(sc.sql) LIMIT 10000",
                             [.int(rev), .int(top)] + sc.args) {
            guard let series = r[0].text, let scope = r[1].text, want?.contains(series) ?? true, let key = try row(scope, &rows, depth: q.depth) else { continue }
            let gauge = TimelineSources.seriesType[series] == "gauge"
            let n = r[4].int ?? 1
            metrics.append(.point(series: series, scope: key, t: r[2].int ?? 0, value: n <= 1 || !gauge ? (r[3].real ?? 0) : (r[3].real ?? 0) / Double(n)))
        }
        let fresh = rows.rows.filter { !known.contains($0.key) }.map(\.value).sorted { $0.scope < $1.scope }
        return TimelineBatch(events: events, metrics: metrics, rows: fresh, now: now, resume: String(max(rev, top)))
    }
}
