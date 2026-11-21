import Foundation

// 747: the daemon's side of the timeline — the indexer started, poked by every write, caught up at start, every 30
// seconds for the chat server's rooms and a space's frames, and hourly for everything.

extension HostCore {
    /// The daemon only: register the store's pokes and keep `timeline.sqlite` caught up. Never on the actor's time: the
    /// indexer has its own queue.
    public nonisolated func startTimeline() async {
        guard let ix = timeline else { return }
        // Only the daemon indexes: a write pokes the indexer once this ran (a core in a test or in-process never does).
        metrics?.onWrite = { [weak ix] in ix?.poke(.metrics) }
        TimelineSignal.register(store.root.path) { [weak ix] p in ix?.poke(p) }
        ix.poke(.all)
        // Retention (14.5a: the history file and the four new records only): 5 minutes after the start, then hourly, and
        // soon after a retention setting changes.
        Task.detached { [weak ix] in
            try? await Task.sleep(for: .seconds(300))
            var last = ""
            var minutes = 60
            while !Task.isCancelled, let ix {
                let all = TimelineRetentionSettings.all()
                let words = all.keys.sorted().map { "\($0)=\(TimelineRetentionSettings.words(all[$0]!.retention))" }.joined(separator: ",")
                if minutes >= 60 || words != last {
                    _ = ix.prune(dryRun: false, retention: all)
                    last = words
                    minutes = 0
                }
                try? await Task.sleep(for: .seconds(60))
                minutes += 1
            }
        }
        Task.detached { [weak ix] in
            var round = 0
            while !Task.isCancelled, let ix {
                try? await Task.sleep(for: .seconds(30))
                round += 1
                ix.poke(.chat)
                ix.poke(.runs)
                if round % 120 == 0 { ix.poke(.all) }
            }
        }
    }

    /// Something the timeline keeps changed (a sample, a record written elsewhere).
    nonisolated func timelinePoke(_ p: TimelinePoke) { timeline?.poke(p) }
}

/// What a timeline op carries (`HostRequest.timeline`), strictly decoded: nothing but these fields.
public struct TimelineRequest: Codable, Equatable, Sendable {
    public var query: TimelineQuery?
    /// The live feed's resume token (a `rev`).
    public var resume: String?
    /// `timeline-retention`: what a prune would remove (`dryRun`), or prune now (`prune`).
    public var dryRun: Bool?
    public var prune: Bool?
    /// `timeline-rebuild`: start from an empty derived store.
    public var clean: Bool?
    public init(query: TimelineQuery? = nil, resume: String? = nil, dryRun: Bool? = nil, prune: Bool? = nil, clean: Bool? = nil) {
        self.query = query; self.resume = resume; self.dryRun = dryRun; self.prune = prune; self.clean = clean
    }
    public static let maximumBytes = 256 << 10
    static let fields: Set<String> = ["query", "resume", "dryRun", "prune", "clean"]
    static let queryFields: Set<String> = ["timeline", "type", "scope", "depth", "from", "to", "bin", "tz", "where", "q", "filters", "series", "limit", "cursor"]

    public static func decode(_ v: JSONValue?) throws -> TimelineRequest {
        guard let v else { return TimelineRequest() }
        let data = try HostWire.encoder.encode(v)
        guard data.count <= maximumBytes else { throw HostError(.invalid, "a timeline request is at most \(maximumBytes / 1024) KiB") }
        guard case .object(let o) = v else { throw HostError(.invalid, "a timeline request is an object") }
        if let bad = o.keys.first(where: { !fields.contains($0) }) { throw HostError(.invalid, "a timeline request has no field \(bad)") }
        if case .object(let q)? = o["query"], let bad = q.keys.first(where: { !queryFields.contains($0) }) {
            throw HostError(.invalid, "a timeline query has no field \(bad)")
        }
        do { return try HostWire.decoder.decode(TimelineRequest.self, from: data) } catch {
            throw HostError(.invalid, "not a timeline/1 request: \(error.localizedDescription)")
        }
    }
}

/// `timeline-retention`'s answer (Dozable's own, not the contract's): each source's retention and setting, the derived
/// store's size, the samples' cost, and — with a dry run or a prune — what each source would lose or lost.
public struct TimelineRetentionReport: Codable, Equatable, Sendable {
    public struct Source: Codable, Equatable, Sendable {
        public var source: String
        public var setting: String
        public var retention: TimelineEffectiveRetention
        /// A dry run or a prune: rows removed (or that would be), by kind of row.
        public var removed: [String: Int]?
    }
    public var sources: [Source]
    public var bytes: Int64
    public var indexing: Int?
    public var sampler: ResourceSampler.Cost?
    public var pruned: Bool?
    public var dryRun: Bool?
    public var now: Int64
}

extension TimelineRetentionReport {
    init(sources: [Source], pruned: Bool?, dryRun: Bool?, bytes: Int64, indexing: Int?, sampler: ResourceSampler.Cost?, now: Int64) {
        self.init(sources: sources, bytes: bytes, indexing: indexing, sampler: sampler, pruned: pruned, dryRun: dryRun, now: now)
    }
    var ordered: Self { self }
}

extension HostCore {
    /// The derived store as a query reads it: its own read-only connection (an empty store when there is no file yet).
    nonisolated func timelineEngine() throws -> TimelineQueryEngine {
        let url = TimelineStore.url(store)
        let t: TimelineStore
        if FileManager.default.fileExists(atPath: url.path) { t = try TimelineStore(url: url, readOnly: true) } else { t = try TimelineStore.empty() }
        return TimelineQueryEngine(store: t, host: MacDisplayName.scope(), now: TimelineClock.nowMs(), indexing: timeline?.progress)
    }

    func performTimeline(_ r: HostRequest) async throws -> JSONValue {
        let req = try TimelineRequest.decode(r.timeline)
        switch r.op {
        case .timelineCatalog:
            return try JSONValue(encoding: try timelineEngine().catalog())
        case .timelineQuery:
            guard let q = req.query else { throw HostError(.invalid, "a timeline query is needed") }
            return try JSONValue(encoding: try timelineEngine().query(q))
        case .timelineRetention:
            return try JSONValue(encoding: try timelineRetention(req))
        case .timelineRebuild:
            guard let ix = timeline else { throw HostError(.unavailable, "a rebuild needs the daemon (doz daemon start)") }
            let clean = req.clean == true
            await Task.detached { ix.rebuild(clean: clean) }.value
            return try JSONValue(encoding: try timelineRetention(TimelineRequest()))
        default:
            throw HostError(.invalid, "\(r.op.rawValue) is a stream (doz timeline tail)")
        }
    }

    nonisolated func timelineRetention(_ req: TimelineRequest) throws -> TimelineRetentionReport {
        var removed: [String: [String: Int]]?
        if req.prune == true {
            guard let ix = timeline else { throw HostError(.unavailable, "a prune needs the daemon (doz daemon start); --dry-run shows what it would remove") }
            let rep = ix.prune(dryRun: false)
            if let why = rep.refused { throw HostError(.failed, "nothing was pruned: \(why)") }
            removed = rep.removed
        } else if req.dryRun == true {
            let rep: TimelinePruneReport
            if let ix = timeline { rep = ix.prune(dryRun: true) } else {
                let url = TimelineStore.url(store)
                let t = FileManager.default.fileExists(atPath: url.path) ? try TimelineStore(url: url, readOnly: true) : try TimelineStore.empty()
                rep = TimelinePruner(store: store, timeline: t, retention: TimelineRetentionSettings.all(), now: TimelineClock.nowMs()).run(dryRun: true)
            }
            if let why = rep.refused { throw HostError(.failed, why) }
            removed = rep.removed
        }
        let e = try timelineEngine()
        let eff = try e.effective(TimelineSources.kept.map(\.name))
        let sources = eff.map { r in TimelineRetentionReport.Source(source: r.source, setting: TimelineRetentionSettings.key(r.source), retention: r,
                                                                    removed: removed.map { $0[r.source] ?? [:] }) }
        return TimelineRetentionReport(sources: sources, pruned: req.prune == true ? true : nil, dryRun: req.dryRun == true ? true : nil, bytes: FileManager.default.fileExists(atPath: TimelineStore.url(store).path)
                                       ? (try? TimelineStore(url: TimelineStore.url(store), readOnly: true).size) ?? 0 : 0,
                                       indexing: timeline?.progress, sampler: readOnly ? nil : sampler.cost, now: e.now).ordered
    }

    /// The live feed: a batch whenever something the query keeps changed (at most one a second), from `resume` on; a
    /// token older than what retention removed since ends it with `reset` (the client queries afresh).
    public nonisolated func timelineBatches(_ r: HostRequest) -> AsyncStream<HostMessage> {
        AsyncStream { cont in
            let task = Task.detached { [self] in
                let req: TimelineRequest
                do { req = try TimelineRequest.decode(r.timeline) } catch {
                    cont.yield(.failure(error as? HostError ?? HostError(.invalid, "\(error)"))); cont.finish(); return
                }
                guard let q = req.query else { cont.yield(.failure(HostError(.invalid, "a timeline query is needed"))); cont.finish(); return }
                var token = Int64(req.resume ?? "") ?? ((try? self.timelineEngine().store.currentRev) ?? 0)
                var quiet = 0
                while !Task.isCancelled {
                    guard let e = try? self.timelineEngine() else { try? await Task.sleep(for: .seconds(1)); continue }
                    guard let b = try? e.batch(q, after: token) else {
                        cont.yield(HostMessage(result: .object(["reset": .bool(true)])))
                        cont.finish()
                        return
                    }
                    let next = Int64(b.resume ?? "") ?? token
                    if !b.events.isEmpty || !b.metrics.isEmpty || quiet >= 15 {
                        cont.yield(HostMessage(result: (try? JSONValue(encoding: b)) ?? .null))
                        quiet = 0
                    } else { quiet += 1 }
                    token = next
                    try? await Task.sleep(for: .seconds(1))
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}
