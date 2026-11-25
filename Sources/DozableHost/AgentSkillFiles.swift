import DozableKit
import Foundation

/// The chat skills an agent Dozable starts in a workspace is told to READ, by path (never installed: doz writes nothing
/// into `~/.claude` or any agent's config). Each is a `SKILL.md` doz carries in its own resource bundle (`ShippedSkills`:
/// `libexec/doz/DozableKit_DozableKit.bundle/skills/NAME/SKILL.md` in a release, beside `.build/debug/doz` in a build) — the
/// same text as `docs/chat/skills/NAME/SKILL.md`. START names where the agent reads it:
/// - on this Mac (unfenced or fenced): the file's resolved absolute path; a fenced session's profile lets it read exactly
///   those files (`MacFence.chatSkillFiles`), as it does doz and dozchat;
/// - in a micro VM: a Mac path is not there, so the file is copied into the VM by the same exec that puts START there,
///   under `~/.doz-workspace/skills/NAME/SKILL.md` (the image user's home), and START names that path.
/// A skill this install does not carry is said plainly in START (`ManagerKickoff.skillLines`).
public enum AgentSkillFiles {
    /// The chat skills doz carries for its agents.
    public static let chatSkills = ["chat-room-member", "chat-worker"]
    /// A manager's and a worker's, in START's order.
    public static let manager = ["chat-room-member"]
    public static let worker = ["chat-worker", "chat-room-member"]
    /// Where they are copied in a VM, under the image user's home.
    public static let vmFolder = ManagerLaunch.vmStartFolder + "/skills"

    /// The resolved absolute path of a shipped skill's file on this Mac, or nil (this install does not carry it, or its
    /// path is not one a fence profile can name).
    public static func macPath(_ name: String, in dir: URL? = ShippedSkills.directory()) -> String? {
        guard let u = ShippedSkills.locate(name, in: dir), let p = MacFencePaths.resolve(u.path), MacFencePaths.pathProblem(p) == nil else { return nil }
        return p
    }

    /// The files a fenced session may read: every chat skill this install carries.
    public static func forFence(in dir: URL? = ShippedSkills.directory()) -> [String] { chatSkills.compactMap { macPath($0, in: dir) } }

    /// Where an agent in `isolation` reads each of `names` (absent: this install does not carry it).
    public static func paths(_ names: [String], isolation: ManagerIsolation, in dir: URL? = ShippedSkills.directory()) -> [String: String] {
        var out: [String: String] = [:]
        for n in names {
            guard let p = macPath(n, in: dir) else { continue }
            out[n] = isolation == .vm ? "~/" + vmFolder + "/" + n + "/SKILL.md" : p
        }
        return out
    }

    /// The files to copy into a VM, by name (those this install carries).
    public static func vmCopies(_ names: [String], in dir: URL? = ShippedSkills.directory()) -> [String: Data] {
        var out: [String: Data] = [:]
        for n in names { if let p = macPath(n, in: dir), let d = FileManager.default.contents(atPath: p) { out[n] = d } }
        return out
    }
}
