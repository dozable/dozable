import Darwin
import Foundation

// A persisted fenced agent's memory (`persist: { x: { agent: NAME } }`). A fenced session's private agent folder is cleared
// at every open but its transcripts (`MacAgentConfig.prepare`), so its Claude Code memory (`projects/<folder>/memory/`)
// would not survive. `down` captures it — before anything is forgotten — into `<store>/workspaces/W/memory/<agent>/`
// (0700/0600, regular files only, no link followed, read by descriptor, at most 2 MiB and 200 files, `memory.json`
// listing `{isolation: "fenced", files [{path, sha256}]}`); the SAME agent's next fenced session (its session in the same
// workspace, a live worker whose space keeps its memory) gets it back after the clearing — never `~/.claude` (a shared
// agent folder is never seeded), never another agent's or another workspace's session. Switching fenced ↔ unfenced resets
// it. `SpaceMemoryTests`.

public enum SpaceMemory {
    public static let maximumBytes = 2 << 20
    public static let maximumFiles = 200
    public static let manifestName = "memory.json"

    public struct Manifest: Codable, Equatable, Sendable {
        public struct File: Codable, Equatable, Sendable {
            /// Relative to the agent folder: `projects/<folder>/memory/…`.
            public var path: String
            public var sha256: String
        }
        public var isolation: String
        public var files: [File]
    }

    /// The memory files under `agentDir/projects/*/memory/` (regular files, no link, bounded), relative to `agentDir`.
    static func listing(_ agentDir: String) throws -> [(rel: String, data: Data)] {
        var out: [(String, Data)] = []
        var total = 0
        let projects = agentDir + "/projects"
        guard MacFenceHostFS.kind(projects) == S_IFDIR else { return [] }
        var problem: String?
        MacFenceHostFS.walk(projects, maximum: 20_000, maxDepth: 8) { path, mode in
            let rel = String(path.dropFirst(agentDir.count + 1))
            let parts = rel.split(separator: "/")
            // projects/<folder>/memory/… only.
            if parts.count >= 3, parts[2] != "memory" { return false }
            guard mode == S_IFREG, parts.count >= 4 else { return mode == S_IFDIR }
            guard problem == nil else { return false }
            guard out.count < maximumFiles else { problem = "more than \(maximumFiles) memory files"; return false }
            guard let d = try? MacFenceHostFS.readRegular(path, maximum: maximumBytes) else { return false }
            total += d.count
            guard total <= maximumBytes else { problem = "more than \(maximumBytes >> 20) MiB of memory"; return false }
            out.append((rel, d))
            return false
        }
        if let problem { throw HostError(.invalid, "the agent's memory was not kept: \(problem)") }
        return out
    }

    /// Captures the memory of the fenced agent folder `agentDir` into `dest` (replaced whole: written beside it, then renamed
    /// over it). Answers how many files.
    @discardableResult
    public static func capture(agentDir: String, into dest: String) throws -> Int {
        let files = try listing(agentDir)
        let parent = (dest as NSString).deletingLastPathComponent
        try MacFenceHostFS.ensureDirectory(parent)
        let temp = parent + "/.new-" + (dest as NSString).lastPathComponent + "-\(UInt32.random(in: 0...UInt32.max))"
        try MacFenceHostFS.ensureDirectory(temp)
        do {
            var m = Manifest(isolation: "fenced", files: [])
            for f in files {
                let dir = temp + "/" + (f.rel as NSString).deletingLastPathComponent
                try MacFenceHostFS.ensureDirectory(dir)
                try MacFenceHostFS.writeAtomically(f.data, dir: dir, name: (f.rel as NSString).lastPathComponent)
                m.files.append(.init(path: f.rel, sha256: WorkspaceStore.sha256(f.data)))
            }
            try MacFenceHostFS.writeAtomically(try HostWire.prettyEncoder.encode(m), dir: temp, name: manifestName)
            if MacFenceHostFS.kind(dest) != nil { try MacFenceHostFS.remove(dest) }
            guard rename(temp, dest) == 0 else { throw HostError(.failed, "the memory could not be put in place: \(String(cString: strerror(errno)))") }
        } catch {
            try? MacFenceHostFS.remove(temp)
            throw error
        }
        return files.count
    }

    /// Seeds the memory kept in `from` into the private agent folder `agentDir` (after its clearing): each file the manifest
    /// names, whose bytes still hash to it, written under `projects/<folder>/memory/` — nothing else. Answers how many.
    @discardableResult
    public static func seed(from: String, into agentDir: String) throws -> Int {
        let m = try HostWire.decoder.decode(Manifest.self, from: MacFenceHostFS.readRegular(from + "/" + manifestName, maximum: 1 << 20))
        guard m.isolation == "fenced" else { return 0 }
        var n = 0
        for f in m.files {
            let parts = f.path.split(separator: "/")
            guard parts.count >= 4, parts[0] == "projects", parts[2] == "memory", !parts.contains("..") else { continue }
            let d = try MacFenceHostFS.readRegular(from + "/" + f.path, maximum: maximumBytes)
            guard WorkspaceStore.sha256(d) == f.sha256 else { continue }
            let dir = agentDir + "/" + (f.path as NSString).deletingLastPathComponent
            try MacFenceHostFS.ensureDirectory(dir)
            try MacFenceHostFS.writeAtomically(d, dir: dir, name: (f.path as NSString).lastPathComponent)
            n += 1
        }
        return n
    }

    /// Where the kept memory of the agent whose fenced session is `session` is (nil: none): a live worker of a workspace a
    /// space file made, whose space keeps that agent's memory as fenced, in this store.
    public static func seedFolder(store: String, session: String) -> String? {
        let ws = WorkspaceStore(store: DozableStore(root: URL(fileURLWithPath: store)))
        for rec in ws.records() {
            guard let ref = SpaceRecordRef.of(rec), ref.purgedAt == nil else { continue }
            for a in rec.agents where a.isLiveWorker && a.place.mac == true && a.place.session == session && a.isolation == "fenced" {
                guard ref.memoryIsolation?[a.name] == "fenced", ref.owned?.agents[a.name] == "persisted" else { continue }
                let dir = WorkspaceStore.resolved(ws.folder(rec.name)) + "/memory/" + a.name
                if MacFenceHostFS.kind(dir + "/" + manifestName) == S_IFREG { return dir }
            }
        }
        return nil
    }
}
