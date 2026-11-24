import Darwin
import Foundation

// The run journal in the daemon (767; `RunJournal.swift` for the shapes and rules): `workspace-journal` (read — in-process
// when no daemon runs), `workspace-journal-add` (append to the open run: the daemon's) and the follower `-journal-follow`
// serves (`HostServer`). Each is gated before it reaches here (`ActionClasses`: journal.read, journal.write or
// journal.write:KIND, evidence.attach); correcting another's entry is decided here, once the entry is read
// (journal.supersede). The owner is never gated. docs/engineering/journal.md.

/// A file attached to an entry, staged before the entry is appended.
struct StagedEvidence: Sendable {
    var evidence: JournalEvidence
    /// The staged copy's name in the run's `evidence/` (nil: not copied).
    var staging: String?
}

extension HostCore {
    nonisolated var journals: RunJournalStore { RunJournalStore.shared(store.root.path) }

    // MARK: read

    /// `workspace-journal`: a run's entries (`run`, default the open run, else the last), superseded ones marked; or, with
    /// `kind` (what `doz workspace wait` polls), the effective entries of that kind in the open run — after `after` (`RUN#SEQ`,
    /// across later runs) when given; an unknown point is 65.
    func workspaceJournalRead(_ r: HostRequest) throws -> WorkspaceJournal {
        let w = r.workspaceRequest ?? WorkspaceRequest()
        let n = try workspaceName(w)
        let j = w.journal ?? WorkspaceJournalRequest()
        guard let rec = try workspaces.read(n) else {
            // A deleted workspace: its runs' archives remain, and a run named reads from there.
            if let run = j.run, JournalCursor.isAnyRunName(run), MacFenceHostFS.kind(journals.archiveFolder(n, run) + "/journal.jsonl") == S_IFREG {
                return WorkspaceJournal(workspace: n, run: run, open: false, entries: JournalRead.markSuperseded(try journals.entries(n, run)))
            }
            throw HostError(.notFound, "\(n) is not a workspace (doz workspace ls)")
        }
        if let kind = j.kind {
            guard JournalKinds.isValid(kind) else { throw HostError(.invalidValue, "\(kind.prefix(70)) is not a kind") }
            var out: [JournalEntry] = []
            if let a = j.after {
                guard let c = JournalCursor.entry(a), let i = rec.runs.firstIndex(where: { $0.id == c.run }) else {
                    throw HostError(.invalidValue, "--after \(a.prefix(60)): \(n) has no such entry")
                }
                let first = try journals.entries(n, c.run)
                guard c.seq == 0 || first.contains(where: { $0.seq == c.seq }) else {
                    throw HostError(.invalidValue, "--after \(a.prefix(60)): run \(c.run) has no entry \(c.seq)")
                }
                out += JournalRead.effective(first).filter { $0.seq > c.seq && $0.kind == kind }
                for run in rec.runs[(i + 1)...] { out += JournalRead.effective(try journals.entries(n, run.id)).filter { $0.kind == kind } }
            } else if let open = rec.openRun {
                out = JournalRead.effective(try journals.entries(n, open.id)).filter { $0.kind == kind }
            }
            return WorkspaceJournal(workspace: n, run: rec.openRun?.id, open: rec.openRun != nil, entries: out)
        }
        let run: WorkspaceRun?
        if let id = j.run {
            guard let x = rec.runs.first(where: { $0.id == id }) else { throw HostError(.notFound, "\(n) has no run \(id.prefix(40)) (doz workspace runs \(n))") }
            run = x
        } else {
            run = rec.openRun ?? rec.runs.last
        }
        guard let run else { return WorkspaceJournal(workspace: n, run: nil, open: false, entries: []) }
        return WorkspaceJournal(workspace: n, run: run.id, open: run.isOpen, entries: JournalRead.markSuperseded(try journals.entries(n, run.id)))
    }

    // MARK: add

    /// `workspace-journal-add`: one entry appended to the open run — the daemon sets id, seq, at, by and evidence; the text
    /// and data are swept; the line is fsynced (and its follow line) before the answer.
    func workspaceJournalAdd(_ r: HostRequest) async throws -> JournalEntry {
        guard !readOnly else { throw HostError(.unavailable, "workspace-journal-add needs the daemon") }
        let w = r.workspaceRequest ?? WorkspaceRequest()
        let n = try workspaceName(w)
        let j = w.journal ?? WorkspaceJournalRequest()
        let by = try describer(r)
        guard let kind = j.kind, !kind.isEmpty else { throw HostError(.usage, "which kind? doz workspace journal \(n) add KIND [TEXT]") }
        try JournalKinds.check(kind)
        if let t = j.text, t.utf8.count > JournalLimits.textBytes {
            throw HostError(.limited, "the text is \(t.utf8.count) bytes — at most \(JournalLimits.textBytes) (the text limit)")
        }
        if let d = j.data {
            let size = (try? HostWire.encoder.encode(d).count) ?? 0
            if size > JournalLimits.dataBytes { throw HostError(.limited, "the data is \(size) bytes — at most \(JournalLimits.dataBytes) (the data limit)") }
        }
        try JournalKinds.checkData(kind, j.data)
        let refs = j.refs ?? []
        if refs.count > JournalLimits.refs { throw HostError(.limited, "\(refs.count) refs — at most \(JournalLimits.refs) (the refs limit)") }
        for x in refs { _ = try JournalRefs.parse(x) }
        if let s = j.supersedes, s < 1 { throw HostError(.invalidValue, "--supersedes \(s): an entry's seq, from 1") }
        let attach = j.attach ?? [], attachRef = j.attachRef ?? []
        if attach.count + attachRef.count > JournalLimits.attachments {
            throw HostError(.limited, "at most \(JournalLimits.attachments) files on one entry (the attachments limit)")
        }
        let rec = try workspaceRecord(n)
        guard let run = rec.openRun else {
            throw HostError(.noOpenRun, "\(n) has no open run: a journal entry is written only while a run is — doz workspace run \(n) opens one")
        }
        let folders = rec.folders.map(\.path)
        let copiedSoFar = try journals.entries(n, run.id).flatMap { $0.evidence ?? [] }.filter { $0.copied != false }.reduce(Int64(0)) { $0 + $1.bytes }
        let staged = try await stageEvidence(n, run.id, attach: attach, attachRef: attachRef, folders: folders, copiedSoFar: copiedSoFar)
        do {
            let e = try commitJournalEntry(r, n, run.id, by: by, kind: kind, j: j, folders: folders, staged: staged)
            // FEEDS: the journal feed — an outcome or a failing review posted to the room (never a working note).
            feedJournalEntry(n, run: run.id, e)
            return e
        } catch {
            discardStaged(n, run.id, staged)
            throw error
        }
    }

    /// Each `--attach` read through no link from inside the run's folders, swept, copied into the run's `evidence/` under a
    /// staging name and hashed; each `--attach-ref` hashed in place. Off the actor: a large file never holds the daemon.
    nonisolated func stageEvidence(_ n: String, _ run: String, attach: [String], attachRef: [String], folders: [String],
                                   copiedSoFar: Int64) async throws -> [StagedEvidence] {
        guard !attach.isEmpty || !attachRef.isEmpty else { return [] }
        var out: [StagedEvidence] = []
        var total = copiedSoFar
        let sweep = ExportSweep.forStore(store)
        do {
            for (path, copy) in attach.map({ ($0, true) }) + attachRef.map({ ($0, false) }) {
                guard let place = JournalEvidenceFiles.resolve(path, folders: folders) else {
                    throw HostError(.invalidValue, "\(DisplayPath.tilde(path)) is not inside the run's folders (\(folders.map { DisplayPath.tilde($0) }.joined(separator: ", ")))")
                }
                let shown = DisplayPath.tilde(path)
                if copy {
                    let room = JournalLimits.copyRunBytes - total
                    guard room > 0 else { throw HostError(.limited, "the run holds \(total) bytes of copied evidence — at most \(JournalLimits.copyRunBytes) (the per-run evidence limit)") }
                    let got = try JournalEvidenceFiles.read(place.real, shown: shown, copyMaximum: min(JournalLimits.copyFileBytes, room + 1))
                    if got.bytes > room {
                        throw HostError(.limited, "\(shown) would take the run past \(JournalLimits.copyRunBytes) bytes of copied evidence (the per-run evidence limit)")
                    }
                    let c = sweep.clean(Array(got.data ?? Data()), file: place.inside)
                    let bytes = Data(c.bytes)
                    let sha = RunArchive.sha(c.bytes)
                    try journals.ensureRunFolder(n, run)
                    let staging = ".staging-\(UUID().uuidString.lowercased())"
                    try MacFenceHostFS.writeAtomically(bytes, dir: journals.runFolder(n, run) + "/evidence", name: staging, sync: true, exclusive: true)
                    total += Int64(bytes.count)
                    out.append(StagedEvidence(evidence: JournalEvidence(ref: "file:" + place.inside, sha256: sha, bytes: Int64(bytes.count),
                                                                         stored: JournalEvidenceFiles.storedName(sha256: sha, inside: place.inside),
                                                                         swept: c.findings.isEmpty ? nil : true),
                                              staging: staging))
                } else {
                    let got = try JournalEvidenceFiles.read(place.real, shown: shown, copyMaximum: nil)
                    out.append(StagedEvidence(evidence: JournalEvidence(ref: "file:" + place.inside, sha256: got.sha256, bytes: got.bytes, copied: false),
                                              staging: nil))
                }
            }
        } catch {
            discardStaged(n, run, out)
            throw error
        }
        return out
    }

    nonisolated func discardStaged(_ n: String, _ run: String, _ staged: [StagedEvidence]) {
        for s in staged { if let st = s.staging { try? MacFenceHostFS.remove(journals.runFolder(n, run) + "/evidence/" + st) } }
    }

    /// The append, on the actor with no suspension: the run still open, the correction's rules, the refs, then the staged
    /// copies put in place, the entry and its follow line written.
    func commitJournalEntry(_ r: HostRequest, _ n: String, _ runID: String, by: String, kind: String, j: WorkspaceJournalRequest,
                            folders: [String], staged: [StagedEvidence]) throws -> JournalEntry {
        let rec = try workspaceRecord(n)
        guard let run = rec.openRun, run.id == runID else {
            if rec.runs.contains(where: { $0.id == runID }) {
                throw HostError(.runClosed, "run \(runID) of \(n) is closed: its journal never changes again — write to the next run")
            }
            throw HostError(.noOpenRun, "\(n) has no open run: doz workspace run \(n) opens one")
        }
        let entries = try journals.entries(n, runID)
        guard entries.count < JournalLimits.entriesPerRun else {
            throw HostError(.limited, "run \(runID) holds \(entries.count) entries — at most \(JournalLimits.entriesPerRun) (the entries limit)")
        }
        let seq = (entries.last?.seq ?? 0) + 1
        if let s = j.supersedes {
            if let refused = JournalCorrection.refusal(supersedes: s, kind: kind, by: by, entries: entries, mayCorrectOthers: true) { throw refused }
            if let orig = entries.first(where: { $0.seq == s }), orig.by != by, by != "owner",
               let refused = PermissionGate.require("journal.supersede", for: r, workspace: n, store: store) {
                throw HostError(.notPermitted, "--supersedes \(s): entry \(s) is \(orig.by)'s — correcting it needs journal.supersede (\(refused.message))")
            }
        }
        let details = try JournalRefs.check(j.refs ?? [], nextSeq: seq, run: run, folders: folders)
        // The staged copies, in place under their content's name (one already there is the same bytes).
        let dir = journals.runFolder(n, runID) + "/evidence"
        for s in staged {
            guard let st = s.staging, let stored = s.evidence.stored else { continue }
            let name = String(stored.dropFirst("evidence/".count))
            if MacFenceHostFS.kind(dir + "/" + name) == S_IFREG {
                try? MacFenceHostFS.remove(dir + "/" + st)
                continue
            }
            let dfd = try MacFenceHostFS.openDirectory(dir)
            defer { close(dfd) }
            if renameatx_np(dfd, st, dfd, name, UInt32(RENAME_EXCL)) != 0 {
                let e = errno
                guard e == EEXIST else { throw HostError(.failed, "the evidence \(name) could not be kept: \(String(cString: strerror(e)))") }
                unlinkat(dfd, st, 0)
            }
        }
        let clean = JournalSweep.apply(ExportSweep.forStore(store), text: j.text, data: j.data)
        let at = JournalTime.string(Date())
        var e = JournalEntry(id: "\(runID)#\(seq)", seq: seq, at: at, by: by, kind: kind)
        e.text = clean.text
        e.data = clean.data
        e.refs = (j.refs ?? []).isEmpty ? nil : j.refs
        e.refDetails = details.isEmpty ? nil : details
        e.evidence = staged.isEmpty ? nil : staged.map(\.evidence)
        e.supersedes = j.supersedes
        e.swept = clean.swept ? true : nil
        try journals.appendEntry(n, runID, e)
        do {
            try journals.appendFollow(n, ["type": .string("entry"), "run": .string(runID), "seq": .number(Double(seq)), "at": .string(at)])
        } catch {
            note(nil, "workspace \(n): entry \(e.id) is written, but its follow line was not: \(error)")
        }
        note(nil, "workspace \(n): journal \(e.id) \(kind) by \(by)")
        return e
    }

    // MARK: follow

    /// The follower for a `workspace-journal-follow` request (an unknown cursor is 65).
    public nonisolated func journalFollower(_ r: HostRequest) throws -> JournalFollower {
        let w = r.workspaceRequest ?? WorkspaceRequest()
        guard let n = w.name, !n.isEmpty else { throw HostError(.invalid, "which workspace? (doz workspace ls)") }
        try WorkspaceName.validate(n)
        guard let rec = try workspaces.read(n) else { throw HostError(.notFound, "\(n) is not a workspace (doz workspace ls)") }
        let j = w.journal ?? WorkspaceJournalRequest()
        return try JournalFollower.make(store: journals, workspace: n, record: rec, afterWseq: j.afterWseq, after: j.after,
                                        untilFinish: j.untilFinish == true)
    }

    // MARK: the archive

    /// A run's journal and its copied evidence, for its archive (`journal.jsonl`, `evidence/…`). Read from the run's folder.
    nonisolated func journalForArchive(_ n: String, _ run: String) -> (journal: Data?, evidence: [(name: String, data: Data)]) {
        guard MacFenceHostFS.kind(journals.journalPath(n, run)) == S_IFREG,
              let d = try? MacFenceHostFS.readRegular(journals.journalPath(n, run), maximum: 512 << 20) else { return (nil, []) }
        var files: [(String, Data)] = []
        var seen = Set<String>()
        for e in JournalRead.parse(d) {
            for ev in e.evidence ?? [] {
                guard let s = ev.stored, seen.insert(s).inserted, let p = journals.evidencePath(n, run, stored: s),
                      let data = try? MacFenceHostFS.readRegular(p, maximum: Int(JournalLimits.copyFileBytes) + 1) else { continue }
                files.append((s, data))
            }
        }
        return (d, files)
    }
}
