import Foundation
import DozableKit
import DozableHost

/// The operations the UI started (590 phase 2). `POST /api/v1/actions` answers 202 at once with the
/// operation; the host call runs here, and its progress lines (the host's `event` lines for that
/// request) and its outcome go to every open page as SSE `op` events — so a 40-second cold start
/// shows its steps in the sandbox's row instead of holding an HTTP request open.
///
/// Bounded, and QUEUED rather than refused (650 — owner: All sandboxes woke 12 at once, each slow from the
/// contention, and past 8 the rest failed "too many operations"). Two lanes, each FIFO:
///   · the LIFECYCLE lane — start, wake, resume, sleep, hibernate, shut down — runs at most `ui.batch_concurrency`
///     (1–8, read whenever a place frees) at once;
///   · every other action runs at most `maxRunning` at once;
///   · a pause, and a resume of a sandbox the monitor last saw PAUSED, are milliseconds of work: they never wait.
/// Beyond its lane's width an operation is accepted (202) and QUEUED: still `state: "running"` (the page reads
/// "running" as "under way" everywhere), with `queued: true` and its `position` (1-based, in its lane), told to the
/// pages at every change. When its turn comes `queued` is cleared and `startedAt` is that moment. A person's own
/// request (`priority`: anything but the page's bulk controls, which send `batch: true`; a key typed in a terminal)
/// goes ahead of every batch one — and a person's repeat of a QUEUED batch operation moves THAT one ahead (the same
/// operation; a repeat of a running one is still 409). Only past `maxQueued` queued is a request refused (503). A
/// queued one can be cancelled (`cancel`): nothing was sent to the host, so nothing was done. The last `keep` ENDED
/// operations are remembered (every running or queued one is kept). The outcome shown is a line this file writes
/// from the result — the host's result itself is never sent on.
///
/// 605: the ring is kept in `<store>/ui.operations.json` (0600; written when an operation starts or
/// ends — the lines this file wrote, never a host result, never a secret). A `doz ui` that restarts while
/// one runs leaves the HOST running it (a plain request is not cancelled when its client goes); the next
/// `doz ui` loads the ring, marks each running one interrupted, and resolves it from the monitor's
/// overview (`reconcile`) — the sandbox reached the phase the operation was for, failed, or is somewhere
/// else — so no page ever shows a forever-running operation. 650: a QUEUED one in the ring was never sent: it is
/// ended at once ("it was not started"), never resolved from the overview.
final class WebOperations: @unchecked Sendable {
    let data: DozableWebData
    let hub: SSEHub
    let monitor: WebMonitor
    let file: URL?
    /// Every action but the lifecycle lane's: at most this many at once.
    let maxRunning = 8
    /// 650: at most this many waiting (in both lanes together); beyond, a request is refused.
    static let maxQueued = 256
    let keep = 50
    /// 650: the lifecycle lane's width (`ui.batch_concurrency`), read whenever a place may free.
    let laneWidth: @Sendable () -> Int
    private let lock = NSLock()
    private var ops: [WebOperation] = []
    private var lastProgress: [String: Date] = [:]
    /// What runs or waits now, by `WebAction.dedupeKey` — a repeat of an in-flight action is refused (409).
    private var inFlight: Set<String> = []
    /// 650: what waits, per lane, in the order it will run; and how many of each lane run now.
    private var queues: [Lane: [Pending]] = [:]
    private var runningIn: [Lane: Int] = [:]
    /// 650: each sandbox's phase as the monitor's last overview said (a resume from pause never waits).
    private var phases: [String: String] = [:]

    /// 650: where an operation waits its turn.
    enum Lane: Hashable, Sendable {
        /// start, wake, resume (but from pause), sleep, hibernate, shutdown — `ui.batch_concurrency` at once.
        case lifecycle
        /// everything else — `maxRunning` at once.
        case general
        /// pause, a resume from pause — never waits.
        case exempt
    }

    /// 650: one operation accepted and not yet sent to the host (or being sent: `run`).
    struct Pending: Sendable {
        let id: String
        let action: WebAction
        let key: String
        let firstLine: String
        let lane: Lane
        var priority: Bool
    }

    static let lifecycleLaneOps: Set<HostOp> = [.start, .wake, .resume, .sleep, .hibernate, .shutdown]

    /// 650: the lane of an action, given the sandbox's phase as last seen (nil: not known — a resume then waits in
    /// the lane, the safe side: it may be a wake's heavy half).
    static func lane(_ a: WebAction, phase: String?) -> Lane {
        guard case .lifecycle(let op, _) = a else { return .general }
        if op == .pause || (op == .resume && phase == Phase.paused.rawValue) { return .exempt }
        return lifecycleLaneOps.contains(op) ? .lifecycle : .general
    }

    static func clampWidth(_ w: Int) -> Int { min(8, max(1, w)) }

    init(data: DozableWebData, hub: SSEHub, monitor: WebMonitor, file: URL? = nil, now: Date = Date(),
         laneWidth: @escaping @Sendable () -> Int = { 3 }) {
        self.data = data
        self.hub = hub
        self.monitor = monitor
        self.file = file
        self.laneWidth = laneWidth
        guard let file, let d = try? Data(contentsOf: file), let saved = try? WebJSON.decoder.decode([WebOperation].self, from: d) else { return }
        ops = saved.map { o in
            var o = o
            if o.state == "running" && o.queued == true {
                // 650: it waited and was never sent — the host has nothing of it to finish.
                o.state = "interrupted"
                o.text = Self.notStartedText
                o.queued = nil
                o.position = nil
            } else if o.state == "running" {
                o.interrupted = true
                o.text = Self.interruptedText
            }
            return o
        }
        trimLocked()
    }

    static let interruptedText = "interrupted — doz ui restarted while it ran; the host carried on"
    static let notStartedText = "doz ui restarted before its turn — it was not started"
    static let cancelledText = "cancelled before its turn — nothing was done"

    /// "queued — next" / "queued — 2 ahead".
    static func queuedText(_ position: Int) -> String { position <= 1 ? "queued — next" : "queued — \(position - 1) ahead" }

    /// Forget the oldest ENDED operations beyond `keep` (a running or queued one is never forgotten). Under the lock.
    private func trimLocked() {
        var excess = ops.count - keep
        guard excess > 0 else { return }
        ops.removeAll { o in
            guard excess > 0, o.state != "running" else { return false }
            excess -= 1
            return true
        }
    }

    /// Write the ring (0600, atomically).
    private func save() {
        guard let file else { return }
        let snapshot = recent
        WebSessionStore.write(snapshot.isEmpty ? nil : try? WebJSON.encoder.encode(snapshot), to: file)
    }

    /// 605: resolve the operations an earlier `doz ui` left running, from an overview.
    func reconcile(_ o: WebOverview, now: Date = Date()) {
        let rows = Dictionary(o.sandboxes.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let changed: [WebOperation] = lock.withLock {
            phases = rows.mapValues(\.phase)          // 650: a resume of a paused sandbox never waits in the lane
            var out: [WebOperation] = []
            for i in ops.indices where ops[i].state == "running" && ops[i].interrupted == true {
                guard let (state, text) = Self.resolution(ops[i], rows: rows, now: now) else { continue }
                ops[i].state = state
                ops[i].text = text
                ops[i].milliseconds = max(0, now.timeIntervalSince(ops[i].startedAt) * 1000)
                out.append(ops[i])
            }
            return out
        }
        guard !changed.isEmpty else { return }
        save()
        for c in changed { hub.broadcast("op", c) }
        onChange?(recent)
    }

    /// The phase each lifecycle operation is for (`rm`: gone; `create`: there).
    static let targetPhase: [String: String] = ["start": "running", "wake": "running", "resume": "running", "pause": "paused",
                                                "sleep": "asleep", "hibernate": "hibernated", "shutdown": "off", "reset": "off"]

    /// What an interrupted operation became, judged from the sandbox now — nil while it is still under
    /// way (busy or booting), for at most 30 minutes.
    static func resolution(_ op: WebOperation, rows: [String: WebSandboxRow], now: Date) -> (String, String)? {
        let unknown = ("interrupted", "doz ui restarted while it ran; the host carried it on — its outcome was not seen here")
        guard let name = op.sandbox, targetPhase[op.action] != nil || op.action == "rm" || op.action == "create" else { return unknown }
        let row = rows[name]
        if let row, row.busy || row.phase == "booting" {
            return now.timeIntervalSince(op.startedAt) > 30 * 60 ? unknown : nil
        }
        switch op.action {
        case "rm":
            return row == nil ? ("done", "\(name) removed — finished while doz ui restarted") : ("interrupted", "doz ui restarted while it ran; \(name) is still there")
        case "create":
            return row != nil ? ("done", "created \(name) — finished while doz ui restarted") : ("interrupted", "doz ui restarted while it ran; \(name) was not created")
        default:
            guard let row else { return ("interrupted", "doz ui restarted while it ran; \(name) is gone") }
            if row.phase == targetPhase[op.action] { return ("done", "\(name) is \(row.phaseLabel) — finished while doz ui restarted") }
            if row.phase == "failed" { return ("failed", "\(name) failed while doz ui restarted — its Boot log says why") }
            return ("interrupted", "doz ui restarted while it ran; the host carried on — \(name) is now \(row.phaseLabel)")
        }
    }

    var recent: [WebOperation] { lock.withLock { ops } }

    /// 591: told whenever an operation starts or ends (the terminals' covers show a running one).
    var onChange: (@Sendable ([WebOperation]) -> Void)?

    /// `firstLine`: what the operation says until the host's first step (591: "a key typed in a
    /// terminal — waking" for a keystroke wake). 650: `priority` — a person's own request (false only for the page's
    /// bulk controls), which goes ahead of every batch one; `phase` — the sandbox's phase when the caller knows it (the
    /// terminal's keystroke wake), else the monitor's last.
    func start(_ action: WebAction, firstLine: String = "requested — waiting for the host", priority: Bool = true,
               phase: String? = nil) throws -> WebOperation {
        let verb = action.hostOp == .openSession ? "open-session" : action == .hostStart ? "host-start"
            : action == .hostRestart ? "host-restart" : action.hostRequest.op.rawValue
        let key = action.dedupeKey
        let width = Self.clampWidth(laneWidth())
        let (op, launches, told): (WebOperation, [Pending], [WebOperation]) = try lock.withLock {
            if inFlight.contains(key) {
                // 650: a person's own request for what a BATCH has queued — that operation goes ahead of the batch.
                if priority, let (lane, i) = queuedIndex(key: key), queues[lane]?[i].priority == false {
                    var p = queues[lane]!.remove(at: i)
                    p.priority = true
                    enqueueLocked(p)
                    let told = renumberLocked()
                    return (ops.first { $0.id == p.id }!, [], told)
                }
                // The same action on the same thing is already under way (a double click, a second tab).
                throw WebRejection.alreadyRunning
            }
            let lane = Self.lane(action, phase: phase ?? action.sandbox.flatMap { phases[$0] })
            if lane == .exempt {
                guard runningIn.values.reduce(0, +) < Self.maxQueued else { throw WebRejection.tooManyOperations }
            } else {
                guard queues.values.reduce(0, { $0 + $1.count }) < Self.maxQueued else { throw WebRejection.tooManyOperations }
            }
            inFlight.insert(key)
            let op = WebOperation(id: String(WebRandom.token().prefix(12)), action: verb, label: action.label, sandbox: action.sandbox,
                                  state: "running", text: firstLine, startedAt: Date(), milliseconds: nil)
            ops.append(op)
            trimLocked()
            let p = Pending(id: op.id, action: action, key: key, firstLine: firstLine, lane: lane, priority: priority)
            var launches: [Pending] = []
            if lane == .exempt { beginLocked(p); launches.append(p) } else { enqueueLocked(p) }
            launches += pumpLocked(width: width)
            var told = launches.compactMap { l in ops.first { $0.id == l.id } }
            told += renumberLocked()
            return (ops.first { $0.id == op.id }!, launches, told)
        }
        tell(told)
        for p in launches { run(p) }
        return op
    }

    /// 650: cancel operations still QUEUED (nothing was sent for them); the others are answered back unchanged.
    func cancel(_ ids: [String]) -> WebOperationsCancelled {
        let (result, told): (WebOperationsCancelled, [WebOperation]) = lock.withLock {
            var r = WebOperationsCancelled(cancelled: [], notQueued: [])
            var told: [WebOperation] = []
            for id in ids {
                guard let (lane, i) = queuedIndex(id: id) else { r.notQueued.append(id); continue }
                let p = queues[lane]!.remove(at: i)
                inFlight.remove(p.key)
                if let k = ops.firstIndex(where: { $0.id == id }) {
                    ops[k].state = "interrupted"
                    ops[k].text = Self.cancelledText
                    ops[k].queued = nil
                    ops[k].position = nil
                    told.append(ops[k])
                }
                r.cancelled.append(id)
            }
            told += renumberLocked()
            trimLocked()
            return (r, told)
        }
        tell(told)
        return result
    }

    /// 650: the changed operations to every page (each once, its latest), then the ring written, the covers told.
    private func tell(_ told: [WebOperation]) {
        guard !told.isEmpty else { return }
        var seen = Set<String>()
        let latest = lock.withLock { Dictionary(ops.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
        for o in told where seen.insert(o.id).inserted { hub.broadcast("op", latest[o.id] ?? o) }
        onChange?(recent)
        save()
    }

    /// Where a queued operation waits (under the lock).
    private func queuedIndex(key: String) -> (Lane, Int)? {
        for (lane, q) in queues { if let i = q.firstIndex(where: { $0.key == key }) { return (lane, i) } }
        return nil
    }
    private func queuedIndex(id: String) -> (Lane, Int)? {
        for (lane, q) in queues { if let i = q.firstIndex(where: { $0.id == id }) { return (lane, i) } }
        return nil
    }

    /// Into its lane: a person's own request after the other priority ones, ahead of every batch one (under the lock).
    private func enqueueLocked(_ p: Pending) {
        var q = queues[p.lane] ?? []
        if p.priority, let i = q.firstIndex(where: { !$0.priority }) { q.insert(p, at: i) } else { q.append(p) }
        queues[p.lane] = q
    }

    /// Its turn: counted as running, no longer queued, its times its own from now (under the lock).
    private func beginLocked(_ p: Pending) {
        runningIn[p.lane, default: 0] += 1
        guard let k = ops.firstIndex(where: { $0.id == p.id }) else { return }
        if ops[k].queued == true {
            ops[k].queued = nil
            ops[k].position = nil
            ops[k].startedAt = Date()
            ops[k].text = p.firstLine
        }
    }

    /// Whatever may run now, taken from the front of each lane (under the lock).
    private func pumpLocked(width: Int) -> [Pending] {
        var out: [Pending] = []
        for (lane, w) in [(Lane.lifecycle, width), (Lane.general, maxRunning)] {
            while runningIn[lane, default: 0] < w, let p = queues[lane]?.first {
                queues[lane]!.removeFirst()
                beginLocked(p)
                out.append(p)
            }
        }
        return out
    }

    /// Each queued operation's place, set where it moved (under the lock) — the ones that changed.
    private func renumberLocked() -> [WebOperation] {
        var changed: [WebOperation] = []
        for lane in [Lane.lifecycle, Lane.general] {
            for (i, p) in (queues[lane] ?? []).enumerated() {
                guard let k = ops.firstIndex(where: { $0.id == p.id }) else { continue }
                guard ops[k].queued != true || ops[k].position != i + 1 else { continue }
                ops[k].queued = true
                ops[k].position = i + 1
                ops[k].text = Self.queuedText(i + 1)
                changed.append(ops[k])
            }
        }
        return changed
    }

    /// Send it to the host; at its end, the next ones of the lanes.
    private func run(_ p: Pending) {
        let t0 = ContinuousClock.now
        let action = p.action, id = p.id
        let request = action.hostRequest
        Task {
            let outcome: (String, String)
            do {
                let onEvent: @Sendable (HostEvent) -> Void = { [weak self] e in self?.progress(id, e) }
                let result = action == .hostRestart ? try await data.restartHost(onEvent: onEvent)
                                                    : try await data.perform(request, onEvent: onEvent)
                outcome = ("done", Self.summary(action, result))
            } catch {
                outcome = ("failed", HostError.from(error).message)
            }
            let d = ContinuousClock.now - t0
            let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
            let width = Self.clampWidth(laneWidth())
            let (launches, told): ([Pending], [WebOperation]) = lock.withLock {
                var told: [WebOperation] = []
                if let k = ops.firstIndex(where: { $0.id == id }) {
                    ops[k].state = outcome.0
                    ops[k].text = outcome.1
                    ops[k].milliseconds = ms
                    told.append(ops[k])
                }
                runningIn[p.lane, default: 1] -= 1
                inFlight.remove(p.key)
                lastProgress[id] = nil
                let launches = pumpLocked(width: width)
                told += launches.compactMap { l in ops.first { $0.id == l.id } }
                told += renumberLocked()
                trimLocked()
                return (launches, told)
            }
            tell(told)
            for l in launches { run(l) }
            await monitor.poke()
        }
    }

    /// A progress line from the host. Download progress ("pulling …: 312 MiB of 640 MiB") is passed
    /// on at most once a second, so a two-minute first start (a pull, a flatten, a bake) visibly
    /// moves instead of looking stuck (590 bug 2).
    private func progress(_ id: String, _ e: HostEvent) {
        if e.kind == .progress || e.kind == .output {
            let now = Date()
            let due: Bool = lock.withLock {
                if let last = lastProgress[id], now.timeIntervalSince(last) < 1 { return false }
                lastProgress[id] = now
                return true
            }
            guard due || (e.completedBytes ?? 0) == (e.totalBytes ?? -1) else { return }
        }
        let text = WebActivity(seq: 0, e).text
        let finished = Self.finishedLine(e)
        if let o = update(id, { o in
            guard o.state == "running" else { return }
            // 617: the steps, the one under way and a short tail — the page's progress panel. A build's raw output goes
            // to the tail only: the header's one line keeps the step in plain words (owner: no apt lines up there).
            var p = o.progress ?? WebOpProgress()
            p.apply(e)
            o.progress = p
            if e.kind == .output { return }
            o.text = text
            // 594 W22: Restart host keeps each sandbox's line (they hibernate in parallel).
            if o.action == "host-restart", let finished { o.lines = (o.lines ?? []) + [finished] }
        }), o.state == "running" { hub.broadcast("op", o) }
    }

    /// 594 W22: a finished step as the progress view writes it (no colour): "✓ hibernated w1 — 0.4 s",
    /// "✗ hibernating w2 — why".
    static func finishedLine(_ e: HostEvent) -> String? {
        switch e.kind {
        case .step: return ProgressTerminal(mode: .animated, color: false).format(.stepDone(e.text ?? "", seconds: (e.milliseconds ?? 0) / 1000))
        case .failed: return ProgressTerminal(mode: .animated, color: false).format(.stepFailed(e.text ?? "", seconds: (e.milliseconds ?? 0) / 1000, error: e.error))
        default: return nil
        }
    }

    private func update(_ id: String, _ change: (inout WebOperation) -> Void) -> WebOperation? {
        lock.withLock {
            guard let i = ops.firstIndex(where: { $0.id == id }) else { return nil }
            change(&ops[i])
            return ops[i]
        }
    }

    /// One line for the page, from the host's result (never the result itself).
    static func summary(_ a: WebAction, _ v: JSONValue) -> String {
        switch a {
        case .lifecycle(let op, let name):
            guard let r = try? v.decode(LifecycleResult.self) else { return "\(op.rawValue) \(name): done" }
            let label = { (s: String) in Phase(rawValue: s).map(PhaseName.label) ?? s }
            if !r.changed { return "\(name) is already \(label(r.phase))" }
            if op == .rm { return "\(name) removed" }
            return "\(name): \(label(r.phaseBefore)) → \(label(r.phase)) in \(Self.duration(r.milliseconds))"
        case .create(let name, _):
            return "created \(name) — start it to boot"
        case .openSession(let name, _, _):
            let s = try? v.decode(SessionOpened.self)
            return s.map { "\($0.created ? "started" : "already running:") session \($0.session) in \(name)" } ?? "session opened in \(name)"
        case .pointTake(let name, _, _):
            return (try? v.decode(RestorePoint.self)).map { "took \($0.name) of \(name)" } ?? "restore point taken"
        case .pointRevert(let name, _):
            return (try? v.decode(RestorePoint.self)).map { "\(name) reverted to \($0.name) — start boots it" } ?? "\(name) reverted"
        case .pointFork(_, _, let new):
            return "forked as \(new) — start it to boot"
        case .pointRemove:
            return (try? v.decode(RestorePoint.self)).map { "deleted restore point \($0.name)" } ?? "restore point deleted"
        case .pointSaveImage(_, _, let image, _):
            return "saved image \(image)"
        case .templateCreate(let name, _, let image, _):
            return (try? v.decode(CustomImage.self)).map { "saved \(name)'s root disk as the template \(image) (\(DozableImages.formatBytes($0.allocatedBytes)); no state disk)" }
                ?? "saved the template \(image)"
        case .rename(let name, let new):
            return "renamed \(name) to \((try? v.decode(SandboxInfo.self))?.name ?? new)"
        case .sandboxSetting(let name, let key, let value):
            // 669: the host's own words (`changed`), else what was asked.
            return (try? v.decode(SandboxSettingsReport.self))?.changed ?? (value.map { "\(key) = \($0) for \(name)" } ?? "\(key) of \(name) follows the setting again")
        case .duplicate(let name, let new, _, let o):
            return "duplicated \(name) as \(new) (state disk \(o.copyState == true ? "copied" : "fresh")) — start it to boot"
        case .imageBake(let i):
            return "\(i) baked"
        case .imageRemove(let i):
            return "removed image \(i)"
        case .netPolicy(let name, _):
            return (try? v.decode(NetworkPolicy.self)).map { "\(name): \($0.preset.map { "\($0) preset" } ?? "custom policy"), \($0.rules.count) rules" }
                ?? "\(name): policy changed"
        case .keyPolicy(let name, let p):
            return "\(name): key policy \(p)"
        case .keyRemove(let name, let b):
            return "\(b) removed from \(name)"
        case .accountUse(let name, let acc):
            return "\(name) uses \(acc)"
        case .accountDefault(let acc):
            return "the default account is \(acc)"
        case .accountKeepalive(let on):
            return "keep-alive \(on ? "on" : "off")"
        case .accountVerify(let acc):
            return (try? v.decode([AccountRow].self))?.first { $0.name == acc }.map { "\(acc): \($0.verification ?? $0.state)" } ?? "\(acc) checked"
        case .accountRefresh(let acc):
            let ok = (try? v.decode([AccountRow].self))?.first { $0.name == acc }?.sourceState == "ok"
            return ok ? "\(acc): its key was read again" : "\(acc): its key could not be read — the Accounts page says why"
        case .accountEdit(let acc, let new, let plan):
            let said = [new.map { "renamed \($0)" }, plan.map { "plan \($0)" }].compactMap { $0 }.joined(separator: ", ")
            return "\(acc): \(said)"
        case .accountRemove(let acc):
            return "removed account \(acc)"
        case .onboard(let images, let base):
            let r = try? v.decode(PrepareResult.self)
            // 634: a base preparation is named for people ("the Node.js base"), never `base:node`.
            let said = { (i: PreparationInfo) in i.base.map { "the \(BaseCatalogue.base($0)?.title ?? $0) base" } ?? i.image }
            let preparing = r?.preparations.filter(\.running).map(said) ?? []
            if !preparing.isEmpty { return "preparing \(preparing.joined(separator: ", ")) in the host — it goes on in the background; the onboarding is recorded when it is done" }
            let ready = (base.map { ["the \(BaseCatalogue.base($0)?.title ?? $0) base"] } ?? []) + images
            return ready.isEmpty ? "onboarded (no image prepared now)" : "onboarded — \(ready.joined(separator: ", ")) ready"
        case .hostStart:
            let s = try? v.decode(HostStatus.self)
            return s.map { "the host is running (pid \($0.pid), doz \($0.version))" } ?? "the host is running"
        case .hostRestart:
            let r = try? v.decode(WebHostRestart.self)
            let who = r?.host.map { "the host restarted as doz \($0.version) (pid \($0.pid))" } ?? "the host restarted"
            guard let stop = r?.stop else { return who + " — its sandboxes hibernated; they wake when used" }
            let hib = stop.sandboxes.filter { $0.outcome == "hibernated" }.map(\.name)
            let other = stop.sandboxes.filter { $0.outcome != "hibernated" }.map { "\($0.name): \($0.outcome == "failed" ? "could not hibernate — shut down" : $0.outcome)" }
            var s = who + (hib.isEmpty ? " — nothing was running" : " — hibernated \(hib.joined(separator: ", ")); they wake when used")
            if !other.isEmpty { s += " (" + other.joined(separator: "; ") + ")" }
            return s
        case .builderStart:
            let s = try? v.decode(ContainerToolStatus.self)
            return s?.state == "ready" ? "Apple's container services are running — Dockerfiles can be built" : (s?.note ?? "Apple's container services started")
        case .builderInstall:
            return "Apple's installer package was opened in macOS Installer — approve it there, then start its services"
        case .sessionEnd(let name, let session):
            let r = try? v.decode(SessionEnded.self)
            return r?.how == "not-running" ? "session \(session) in \(name) was not running" : "ended session \(session) in \(name)"
        case .sessionRestart(let name, let session, _):
            guard let r = try? v.decode(SessionRestarted.self) else { return "restarted session \(session) in \(name)" }
            return "restarted session \(session) in \(name)" + (r.resumed ? " — its conversation continues" : "") + (r.notice.map { " (\($0))" } ?? "")
        case .filesMkdir(let name, let p):
            return "made the folder \(p) in \(name)"
        case .filesNew(let name, let p):
            return "made the file \(p) in \(name)"
        case .filesMove(let name, let p, let to):
            return "moved \(p) → \(to) in \(name)"
        case .filesRemove(let name, let p, _):
            let r = try? v.decode(FileChangeResult.self)
            let n = (r?.items ?? 1) - 1
            return "deleted \(p) in \(name)" + (r?.kind == "folder" && n > 0 ? " (\(n) item\(n == 1 ? "" : "s") in it)" : "")
        case .toolsApply(let name):
            let r = (try? v.decode(ToolsLayerReport.self))?.last
            return "\(name): tools — " + (r?.summary ?? "set up")
        case .prepareCancel:
            let ps = (try? v.decode([PreparationInfo].self)) ?? []
            return ps.isEmpty ? "nothing was being prepared" : "cancelling the preparation of \(ps.map(\.image).joined(separator: ", "))"
        case .resourcesRemove, .resourcesClean:
            guard let p = try? v.decode(ResourcePlan.self) else { return "deleted" }
            var s = p.deleted.isEmpty ? "nothing deleted" : "deleted \(p.deleted.count) item\(p.deleted.count == 1 ? "" : "s") — freed \(DozableImages.formatBytes(p.freedBytes))"
            if !p.refused.isEmpty { s += "; refused \(p.refused.count) (\(p.refused[0].reason))" }
            if !p.failed.isEmpty { s += "; \(p.failed.count) failed (\(p.failed[0].reason))" }
            return s
        case .resourcesKernel:
            return (try? v.decode(ResourceKernelChoice.self)).map { "new sandboxes boot \($0.kernel) — existing ones keep theirs" } ?? "kernel chosen"
        }
    }

    static func duration(_ ms: Double) -> String {
        ms < 1000 ? "\(Int(ms.rounded())) ms" : String(format: "%.1f s", ms / 1000)
    }
}
