import Foundation
import DozableKit

/// 648 (painted thumbnails): `session-grids` — the pictures of running sessions as cells, for the dashboard's tiles.
///
/// Each picture is ONE GRID frame on the session's status watcher (`HostCore+Status`, `deckhold pipe` + WATCH): the
/// host already holds one per live session of a running sandbox, so a request adds no guest exec, no attach and no
/// viewer. The rules:
///   - RUNNING sandboxes only; anything else is `not-running` — nothing is woken or started (the page paints the
///     saved screen instead).
///   - Only to a holder that ANNOUNCED GRID (its WATCH answer said `grid=1`: `SessionConnection.gridCapable`). An
///     older holder drops a client on an unknown frame — the session's status watcher — so it is never asked
///     (`no-watcher`, like a session the host has no watcher on).
///   - At most `gridRequestsPerSandbox` requests under way per sandbox (`busy` beyond), at most
///     `SessionConnection.maximumPendingGrids` outstanding frames per watcher, each answered within a second
///     (`timeout`). The page polls at most twice a second; the host does not rate-limit beyond that.
///   - The answer's text is inert (`ScreenGrid.decode`): it came from inside the sandbox.
extension HostCore {
    /// Pictures one request may ask for.
    public static let maximumGridItems = 64
    /// `session-grids` requests under way at once for one sandbox.
    static let gridRequestsPerSandbox = 2

    func sessionGrids(_ r: HostRequest) async throws -> [SessionGridAnswer] {
        guard let items = r.grids, items.count <= Self.maximumGridItems else {
            throw HostError(.invalid, "session-grids: at most \(Self.maximumGridItems) pictures, each a sandbox, a session and a gen")
        }
        // In-process (no host): no watcher exists, and looking never starts one.
        if readOnly { return items.map { .unavailable($0, .noHost) } }

        var answers = [SessionGridAnswer?](repeating: nil, count: items.count)
        var refused: [String: SessionGridAnswer.Reason] = [:]
        var admitted: Set<String> = []
        var asks: [(Int, SessionGridRequest, SessionConnection)] = []
        defer { for s in admitted { gridsInFlight[s] = max(0, (gridsInFlight[s] ?? 1) - 1) } }
        for (i, item) in items.enumerated() {
            guard (try? GuestCommand.validateSessionName(item.session)) != nil else { answers[i] = .unavailable(item, .invalid); continue }
            if let why = refused[item.sandbox] { answers[i] = .unavailable(item, why); continue }
            if !admitted.contains(item.sandbox) {
                if let why = await admitGrids(item.sandbox) {
                    refused[item.sandbox] = why
                    answers[i] = .unavailable(item, why)
                    continue
                }
                admitted.insert(item.sandbox)
            }
            guard let conn = statusWatches[Self.key(item.sandbox, item.session)], !conn.isClosed, conn.gridCapable else {
                answers[i] = .unavailable(item, .noWatcher)
                continue
            }
            asks.append((i, item, conn))
        }
        let got = await withTaskGroup(of: (Int, ScreenGrid.Answer?).self) { group in
            for (i, item, conn) in asks {
                group.addTask { (i, await conn.requestGrid(gen: item.gen)) }
            }
            var out: [(Int, ScreenGrid.Answer?)] = []
            for await a in group { out.append(a) }
            return out
        }
        for (i, answer) in got {
            let item = items[i]
            switch answer {
            case .grid(let g)?: answers[i] = SessionGridAnswer(sandbox: item.sandbox, session: item.session, state: .grid, gen: g.gen, grid: g)
            case .unchanged(let gen)?: answers[i] = SessionGridAnswer(sandbox: item.sandbox, session: item.session, state: .unchanged, gen: gen)
            case .none?: answers[i] = .unavailable(item, .tooLarge)
            case nil: answers[i] = .unavailable(item, .timeout)
            }
        }
        return answers.enumerated().map { $0.element ?? .unavailable(items[$0.offset], .timeout) }
    }

    /// nil: the sandbox may be asked now (counted in `gridsInFlight`); else why not.
    private func admitGrids(_ name: String) async -> SessionGridAnswer.Reason? {
        guard let m = managed[name] else { return .notFound }
        let runs = if let seam = gridRunsForTests { seam(name) } else { await m.sandbox.phase == .running }
        guard runs else { return .notRunning }
        guard (gridsInFlight[name] ?? 0) < Self.gridRequestsPerSandbox else { return .busy }
        gridsInFlight[name, default: 0] += 1
        return nil
    }

    // MARK: tests (no VM: a watcher made by hand, a sandbox said to run)

    func setGridSeamsForTests(runs: (@Sendable (String) -> Bool)?, watchers: [String: [String: SessionConnection]] = [:],
                              inFlight: [String: Int] = [:]) {
        gridRunsForTests = runs
        for (sandbox, sessions) in watchers { for (session, c) in sessions { statusWatches[Self.key(sandbox, session)] = c } }
        gridsInFlight = inFlight
    }
}
