import CryptoKit
import Darwin
import DozableKit
import Foundation

/// What a client asks for a fenced session on this Mac (`HostRequest.macFence`). Its presence means FENCED; the CLI
/// resolves the mode (flag > `DOZ_MAC_FENCE` > `mac.fence` > default) and sends nothing for an unfenced one.
public struct MacFenceRequest: Codable, Equatable, Sendable {
    /// Open the Keychain's services (signing, notarisation) — default closed.
    public var keychain: Bool?
    /// One more folder read-only / read-write each (absolute; resolved and checked by the host).
    public var read: [String]?
    public var write: [String]?
    public init(keychain: Bool? = nil, read: [String]? = nil, write: [String]? = nil) {
        self.keychain = keychain
        self.read = read
        self.write = write
    }
}

/// What widens a fenced session's reach — recorded at each open; a re-open that WIDENS it empties the session's caches
/// first (nothing written under narrower grants is loaded under wider ones).
public struct MacFenceGrants: Codable, Equatable, Sendable {
    public var profile: String
    public var keychain: Bool
    public var readable: [String]
    public var writable: [String]

    static func rank(_ profile: String) -> Int { ["agent": 0, "xcode": 1, "simulator": 2][profile] ?? 3 }

    /// `self` reaches something `old` did not.
    public func widens(_ old: MacFenceGrants?) -> Bool {
        guard let old else { return false }
        if keychain && !old.keychain { return true }
        if Self.rank(profile) > Self.rank(old.profile) { return true }
        if !Set(readable).subtracting(old.readable).subtracting(old.writable).isEmpty { return true }
        if !Set(writable).subtracting(old.writable).isEmpty { return true }
        return false
    }
}

/// The record of a fenced session (`MacSessionRecord.fence`; nil = unfenced, so every earlier record keeps its mode).
/// Never a password, a token or a config's text.
public struct MacFenceRecord: Codable, Equatable, Sendable {
    public var version = 1
    /// `agent` (this release); `xcode` and `simulator` come later.
    public var profile: String
    public var keychain: Bool
    public var readable: [String]
    public var writable: [String]
    public var sessionFolder: String
    public var grants: MacFenceGrants
    public var tag: String
    public var templateVersion: Int
    public var profileSHA256: String
    /// Per repository known at open (its git folder → the sha256 of its config's keys and values).
    public var gitBaseline: [String: String]?
    /// Why the session is stopped (a git config change outside the allowlist), and the processes stopped.
    public var stoppedForGit: String?
    public var stoppedPids: [Int]?

    /// This session's sentinel and the anti-sentinel (`MacFence.sentinel`, `.antiSentinel`).
    public var sentinel: String { sessionFolder + "/etc/sentinel-" + tag }
    public var antiSentinel: String { (sessionFolder as NSString).deletingLastPathComponent + "/.not-fenced" }
    /// The request that opens it again with the same grants.
    public var request: MacFenceRequest {
        MacFenceRequest(keychain: keychain ? true : nil, read: readable.isEmpty ? nil : readable, write: writable.isEmpty ? nil : writable)
    }
}

/// What `doz sessions @mac --json` says of a fenced session.
public struct MacFenceRow: Codable, Equatable, Sendable {
    public var profile: String
    public var keychain: Bool
    public var readable: [String]
    public var writable: [String]
    public var sessionFolder: String
    public var stoppedForGit: String?
    public var templateVersion: Int
    public var profileSHA256: String

    public init(_ r: MacFenceRecord) {
        profile = r.profile
        keychain = r.keychain
        readable = r.readable
        writable = r.writable
        sessionFolder = r.sessionFolder
        stoppedForGit = r.stoppedForGit
        templateVersion = r.templateVersion
        profileSHA256 = r.profileSHA256
    }

    /// The STATE word(s) of `doz sessions @mac`.
    public var state: String {
        if let s = stoppedForGit, !s.isEmpty { return "stopped: git config" }
        return keychain ? "fenced · Keychain open" : "fenced"
    }
}

/// `session-resume`.
public struct SessionResumed: Codable, Equatable, Sendable {
    public var session: String
    public var processes: Int
}

/// `session-quarantine`: what was taken out of a fenced session's git configs, newest first.
public struct SessionQuarantine: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var name: String
        public var text: String
    }
    public var session: String
    public var items: [Item]
}

/// A fenced session on this Mac: everything its Seatbelt profile, environment and session folder are made from — built
/// by the host at each open from the request, the store and the person's home (`MacFence.make`). Paths are resolved.
public struct MacFence: Sendable, Equatable {
    public static let templateVersion = 1
    public static let profileKind = "agent"

    public var places: MacFencePlaces
    public var session: String
    public var workdir: String
    public var sessionFolder: String
    public var readable: [String]
    public var writable: [String]
    public var homeReads: MacFencePaths.HomeReads
    public var keychain: Bool
    public var tag: String
    /// Literal paths inside the folder that are write- and rename-protected (an in-tree `core.hooksPath`, its husky
    /// parent, a git include target).
    public var protectedPaths: [String] = []
    /// The folder's own `.git`: absent, a folder or a file (a worktree's pointer).
    public var workdirGit: mode_t?

    public var tmp: String { sessionFolder + "/tmp" }
    public var cache: String { sessionFolder + "/cache" }
    public var derived: String { sessionFolder + "/derived" }
    public var etc: String { sessionFolder + "/etc" }
    public var ssh: String { sessionFolder + "/ssh" }
    /// Readable ONLY by this session's profile (every other fence closes the whole fence root): how the host tells this
    /// session's processes apart (`MacFenceStop`).
    public var sentinel: String { etc + "/sentinel-" + tag }
    /// Closed to every fence and open to a broad reader — the second half of that test.
    public var antiSentinel: String { places.fenceRoot + "/.not-fenced" }
    /// Every folder the program may write.
    public var writableRoots: [String] { [workdir] + writable }

    public var grants: MacFenceGrants {
        MacFenceGrants(profile: Self.profileKind, keychain: keychain, readable: readable.sorted(), writable: writable.sorted())
    }

    /// A fresh tag: 16 hex.
    public static func newTag() -> String { (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined() }

    public static func sessionFolder(_ places: MacFencePlaces, session: String) -> String { places.fenceRoot + "/" + session }

    /// Build the fence for `session` in `workdir` (both checked here): the extra folders resolved and refused where they
    /// must be, the home's read allowlist for `path`, the folder's git protections. Throws a plain `HostError(.invalid)`.
    public static func make(session: String, workdir given: String, request: MacFenceRequest, places: MacFencePlaces,
                            path: String, fenceRead: [String], hooksPathGlobal: String?, scratch: String) throws -> MacFence {
        if let p = MacFencePaths.pathProblem(places.home) { throw HostError(.invalid, "this Mac's home cannot be fenced: \(p)") }
        guard let wd = MacFencePaths.resolve(given) else { throw HostError(.invalid, "--workdir \(given): not a folder on this Mac") }
        if let why = MacFencePaths.workdirRefusal(wd, places) {
            throw HostError(.invalid, "a fenced session cannot run in \(DisplayPath.tilde(wd)): \(why) — choose a project folder (--workdir DIR), or doz run @mac --unfenced")
        }
        func folders(_ list: [String]?, _ flag: String) throws -> [String] {
            var out: [String] = []
            for d in list ?? [] {
                guard let r = MacFencePaths.resolve(d) else { throw HostError(.invalid, "\(flag) \(d): not on this Mac") }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: r, isDirectory: &isDir), isDir.boolValue else { throw HostError(.invalid, "\(flag) \(d): not a folder") }
                if let why = MacFencePaths.folderRefusal(r, places) { throw HostError(.invalid, "\(flag) \(DisplayPath.tilde(r)): refused — \(why)") }
                if !out.contains(r) { out.append(r) }
            }
            return out
        }
        let writable = try folders(request.write, "--write").filter { $0 != wd }
        let readable = try folders(request.read, "--read").filter { r in r != wd && !writable.contains(r) }
        var fence = MacFence(places: places, session: session, workdir: wd, sessionFolder: sessionFolder(places, session: session),
                             readable: readable, writable: writable,
                             homeReads: MacFencePaths.homeReads(places, path: path, extra: fenceRead, keychain: request.keychain == true),
                             keychain: request.keychain == true, tag: newTag())
        fence.workdirGit = MacFenceHostFS.kind(wd + "/.git")
        fence.protectedPaths = try MacFenceGit.protectedPaths(workdir: wd, hooksPathGlobal: hooksPathGlobal, home: places.home, scratch: scratch)
        return fence
    }

    /// The one line `doz run @mac --fenced` says on stderr.
    public func line() -> String {
        var reach = DisplayPath.tilde(workdir)
        if !writable.isEmpty { reach += " and " + writable.map { DisplayPath.tilde($0) }.joined(separator: ", ") }
        return "fenced: reads and writes \(reach); its own temp and caches; no network yet; "
            + (keychain ? "your Keychain OPEN; " : "your Keychain, ")
            + "secrets and other folders closed — doz run @mac --unfenced for none of this"
    }

    public func record(profileSHA256: String, gitBaseline: [String: String]?) -> MacFenceRecord {
        MacFenceRecord(profile: Self.profileKind, keychain: keychain, readable: readable, writable: writable, sessionFolder: sessionFolder,
                       grants: grants, tag: tag, templateVersion: Self.templateVersion, profileSHA256: profileSHA256,
                       gitBaseline: gitBaseline, stoppedForGit: nil, stoppedPids: nil)
    }

    static func sha256(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
}
