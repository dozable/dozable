import Darwin
import Foundation

/// The Agents / Bots of a store: `<store>/bots/bots.json`, and for each bot `<store>/bots/<name>/` holding
/// `instructions.md` (when given) and `notes.md` (empty, its own to keep).
///
/// - `bots/` and each bot's folder are 0700, made with no link in their path and owned by this user; every file is 0600 and
///   written atomically (`MacFenceHostFS.writeAtomically`). `bots.json` is rewritten whole.
/// - Never a token: a held bot's token is in its keychain item (`BotTokens`), a bot elsewhere's is not kept at all.
///
/// Reading never writes: a read-only command uses the same store in-process. The daemon is the one writer (its bot ops hold
/// the `bots` gate). `BotRecordTests`.
public struct BotStore: Sendable {
    public let store: DozableStore
    /// `<store>/bots`, resolved (no link in it — `/tmp` is one).
    public let root: String
    public static let maximumFileBytes = 4 << 20
    public static let maximumInstructionsBytes = 256 << 10

    public init(store: DozableStore) {
        self.store = store
        root = WorkspaceStore.resolved(store.root.path) + "/bots"
    }

    public var file: String { root + "/bots.json" }
    public func folder(_ name: String) -> String { root + "/" + name }

    // MARK: reading

    /// The bots (an empty file when there is none). A file that cannot be read is an error naming it.
    public func read() throws -> BotsFile {
        guard MacFenceHostFS.kind(file) != nil else { return BotsFile() }
        let d: Data
        do { d = try MacFenceHostFS.readRegular(file, maximum: Self.maximumFileBytes) } catch {
            throw HostError(.failed, "the bots' record cannot be read: \(error)")
        }
        do { return try HostWire.decoder.decode(BotsFile.self, from: d) } catch {
            throw HostError(.failed, "the bots' record cannot be read: \(error.localizedDescription)")
        }
    }

    /// The bots, or none when the file cannot be read (for looks that must never fail: `chat who`, the guards).
    public func readOrEmpty() -> BotsFile { (try? read()) ?? BotsFile() }

    public func readInstructions(_ name: String) -> String? {
        guard ChatNames.refusal(name) == nil,
              let d = try? MacFenceHostFS.readRegular(folder(name) + "/instructions.md", maximum: Self.maximumInstructionsBytes) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    // MARK: writing

    /// Replace `bots.json` whole (atomically; every field this build does not know kept as read).
    public func write(_ f: BotsFile) throws {
        try WorkspaceStore.ensureOwnedDirectory(root)
        var d = try HostWire.prettyEncoder.encode(f)
        d.append(0x0A)
        try MacFenceHostFS.writeAtomically(d, dir: root, name: "bots.json")
    }

    /// The bot's folder (0700) with an empty `notes.md` when it has none yet.
    public func ensureFolder(_ name: String) throws {
        if let why = ChatNames.refusal(name) { throw HostError(.invalid, why) }
        try WorkspaceStore.ensureOwnedDirectory(root)
        try WorkspaceStore.ensureOwnedDirectory(folder(name))
        if MacFenceHostFS.kind(folder(name) + "/notes.md") == nil {
            try MacFenceHostFS.writeAtomically(Data(), dir: folder(name), name: "notes.md")
        }
    }

    /// The instructions copied into the bot's folder; answers their hash and size for the record.
    public func writeInstructions(_ name: String, _ text: Data, at: Date = Date()) throws -> BotInstructions {
        try BotFields.checkInstructions(text)
        try ensureFolder(name)
        try MacFenceHostFS.writeAtomically(text, dir: folder(name), name: "instructions.md")
        return BotInstructions(sha256: BotFields.sha256(text), bytes: text.count, updatedAt: at)
    }
}
