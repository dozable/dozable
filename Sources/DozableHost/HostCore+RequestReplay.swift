import Foundation

/// `--request-id` in the daemon (`RequestReplay`): one id at a time, its first successful answer kept, a replay answered from
/// it with `"replayed": true`, the same id with other arguments refused. A failure is never kept, so a retry runs for real.
extension HostCore {
    var requestReplays: RequestReplayStore { RequestReplayStore(store: store, now: requestReplayNow) }

    func performOnce(_ r: HostRequest, id: String, emit: @escaping @Sendable (HostEvent) -> Void) async throws -> JSONValue {
        try RequestReplay.validate(id)
        guard !readOnly else { throw HostError(.unavailable, "\(r.op.rawValue) needs the daemon") }
        let fields = try RequestReplay.fields(of: r)
        let key = r.op.rawValue + "\u{0}" + id
        await requestGate.lock(key)
        defer { requestGate.unlock(key) }
        let kept = requestReplays
        if let e = kept.read(r.op, id) {
            let differ = RequestReplay.differences(e.fields, fields, op: r.op)
            guard differ.isEmpty else {
                throw HostError(.requestIDReused, "the request id \(id) was used \(Self.ago(e.at, now: requestReplayNow())) for a "
                                + "\(Self.commandName(r.op)) with other arguments (they differ in \(differ.joined(separator: ", "))) — "
                                + "use a new id for a new request")
            }
            guard case .object(var o) = e.answer else { return e.answer }
            o["replayed"] = .bool(true)
            return .object(o)
        }
        var plain = r
        plain.requestID = nil
        let answer = try await perform(plain, emit: emit)
        do { try kept.record(r.op, id, fields: fields, answer: answer) } catch {
            // The work is done; only its replay is lost — a retry would then run again. Said in the daemon's log, never failed.
            FileHandle.standardError.write(Data("doz: the request id \(id) could not be kept: \(error.localizedDescription)\n".utf8))
        }
        return answer
    }

    static func commandName(_ op: HostOp) -> String {
        switch op {
        case .workspaceNew: "doz workspace new"
        case .workerAdd: "doz worker add"
        case .workspaceAdopt: "doz workspace adopt"
        case .permissionsGrant: "doz permissions grant"
        default: op.rawValue
        }
    }

    static func ago(_ at: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(at)))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60) min ago" }
        return "\(s / 3600) h ago"
    }
}
