import Foundation
import DozableKit

// 599c (owner, 2026-10-01: "add a "Quick Add" sandbox that picks defaults for workspace name etc and
// opens it immediately"): one click in doz ui (Quick add), one command in the CLI (`doz new`) — no form.
//
//   · the image: `defaults.image` (or the one asked for);
//   · the name: the image's (claude-sandbox, pi-sandbox, lab-sandbox; -2, -3, … when a sandbox has it or
//     its folder under the projects folder is not empty) — `Workspace.suggestedName`;
//   · the workspace: `<defaults.projects_dir>/<name>`, made when missing (isolated when asked);
//   · the store's default account and the default permissions (nothing is said: the create's defaults).
//
// Prerequisites still apply. What one click cannot decide — the agent needs an account the store does
// not have as its default — is a REQUIREMENT: the UI opens the New Sandbox form with it said; the CLI asks
// on a terminal, as `doz create` does. 635 (owner: Quick add stopped on "Claude Code 2.1.305 is available"):
// an out-of-date image is NOT one — it is used as it is (never rebuilt without the person) and said (`notice`).

/// What Quick add / `doz new` will make.
public struct QuickAddPlan: Codable, Equatable, Sendable {
    public var name: String
    public var image: String
    /// `<projects_dir>/<name>`; nil: isolated.
    public var workspace: String?
    /// `defaults.projects_dir`, expanded.
    public var projectsDir: String
    /// Why one click cannot make it (nil: it can): the New Sandbox form opens with this said.
    public var requirement: String?
    /// `account` — which kind of requirement (635: an out-of-date image is a `notice`, no longer a requirement).
    public var requirementKind: String?
    /// 635: said once it is made, never asked: its image is out of date ("Claude Code 2.1.305 is available …").
    public var notice: String?

    public init(name: String, image: String, workspace: String?, projectsDir: String) {
        self.name = name
        self.image = image
        self.workspace = workspace
        self.projectsDir = projectsDir
    }

    /// "claude-sandbox-2 · claude-code · ~/doz-workspaces/claude-sandbox-2".
    public func line(homes: [String] = DisplayPath.homes()) -> String {
        let ws = workspace.map { DisplayPath.tilde($0, homes: homes) } ?? "isolated"
        return "\(name) · \(image) · \(ws)"
    }
}

public enum QuickAdd {
    /// The name, image and workspace. `name` given: used as it is (refused when taken or not a name);
    /// else the image's, free. Throws only for a given name.
    public static func plan(image: String?, name: String?, isolated: Bool, taken: Set<String>, settings: DozableSettings) throws -> QuickAddPlan {
        let img = image ?? settings.string(SettingKey.defaultImage) ?? "lab"
        let projects = (Workspace.defaultPath(name: "x", settings: settings) as NSString).deletingLastPathComponent
        let chosen: String
        if let n = name {
            guard WebNameCheck.isSandboxName(n) else { throw HostError(.invalid, "the name: 1–40 of a-z 0-9 - (not starting with -) — not \(n)") }
            guard !taken.contains(n) else { throw HostError(.exists, "sandbox \(n) already exists — doz up \(n) attaches to it") }
            chosen = n
        } else {
            chosen = Workspace.suggestedName(image: img, taken: taken, projects: projects)
        }
        return QuickAddPlan(name: chosen, image: img, workspace: isolated ? nil : (projects as NSString).appendingPathComponent(chosen),
                            projectsDir: projects)
    }

    /// What one click cannot decide for a new sandbox of `image` with the default account, or nil.
    /// `network`: the image's network setting (nat/none: no account at all).
    public static func requirement(image: String, network: String?, defaultAccount: String,
                                   accountKinds: [String: AccountKind], openaiDefault: String? = nil,
                                   codexMac: Bool = false, providers: [String: String] = [:],
                                   providerDefaults: [String: String] = [:]) -> (kind: String, text: String)? {
        if AgentCredentials.kinds(image) != nil, network != "nat", network != "none",
           let problem = AgentCredentials.createProblem(image: image, account: nil, defaultAccount: defaultAccount, kinds: accountKinds,
                                                        openaiDefault: openaiDefault, codexMac: codexMac,
                                                        providers: providers, providerDefaults: providerDefaults) {
            return ("account", problem)
        }
        return nil
    }

    /// 635: what Quick add says after making a sandbox of an out-of-date image (`outOfDate`: the image's standing line),
    /// or nil. It is used as it is; rebuilding is the person's, on the Images page.
    public static func notice(image: String, outOfDate: String?) -> String? {
        guard let s = outOfDate else { return nil }
        return "it uses the \(image) image as it is — \(s.replacingOccurrences(of: #" — rebuild when ready: .*$"#, with: "", options: .regularExpression)); Images › Rebuild when you want it"
    }

    /// The image's network setting, for `requirement` (nil for an image without an agent).
    public static func network(image: String, settings: DozableSettings) -> String? {
        guard AgentCredentials.kinds(image) != nil else { return nil }
        return settings.string(SettingKey.network(DozableSettings.imageSection(imageSpecName: image)))
    }
}
