import CryptoKit
import Foundation

/// Where a held bot's token lives: ONE login-keychain item per bot, `doz-bot-<store's 8 hex>-<name>` (account
/// `Keychain.user`), written through the daemon's keychain seam (`services.keychain` — the memory one under
/// `DOZ_TEST_CREDENTIALS=memory`). Never in argv, a record, a log or `--json`; the record keeps only its fingerprint.
///
/// Bot tokens stay out of the launch secrets' ledger (`secrets.json`): its sweep treats an owner that is not `mac.…` as a
/// sandbox, and an older doz would delete a bot's item. Bots have their own prefix and their own sweep
/// (`HostCore.sweepBotTokens`), which only ever lists this store's prefix.
public enum BotTokens {
    public static let servicePrefix = "doz-bot-"

    /// This store's prefix: `doz-bot-<8 hex of the store's path>-` (the store's id as launch secrets have it).
    public static func prefix(store root: URL) -> String {
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return servicePrefix + digest.prefix(8) + "-"
    }

    /// The keychain item of the bot `name` in the store at `root`.
    public static func service(store root: URL, name: String) -> String { prefix(store: root) + name }

    /// 12 hex of the token's SHA-256 — what a person and the log see, never the token.
    public static func fingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    /// The items of this store's prefix that belong to no held, unretired bot (what the sweep deletes).
    public static func orphans(_ items: [KeychainItemInfo], store root: URL, bots: BotsFile) -> [String] {
        let pre = prefix(store: root)
        let live = Set(bots.bots.filter(\.holdsToken).map { service(store: root, name: $0.name) })
        return items.map(\.service).filter { $0.hasPrefix(pre) && !live.contains($0) }.sorted()
    }
}
