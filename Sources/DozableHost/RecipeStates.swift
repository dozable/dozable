import Foundation
import DozableKit

// 669 (659 §0, owner: "If we have 1000 recipes will each appear? definitely not … group them by their state") — a
// recipe's state on this Mac, read from the store alone (no host, never the network):
//
//   in use     at least one sandbox runs its agent;
//   installed  at least one baked image of it is on this Mac (and no sandbox) — or it carries this Mac's values
//              (doz.toml) with no image: listed with the installed ones, tagged "not installed";
//   available  only in a catalogue: reached by search and Browse, never listed by default.
//
// `doz config show` says the first two in one line, `doz recipe ls` has a STATE column, and Settings › Recipes groups
// its list by them.

/// One baked image of a recipe (its base × agent image).
public struct RecipeImage: Codable, Equatable, Sendable {
    public var name: String
    public var allocatedBytes: Int64
    public init(name: String, allocatedBytes: Int64) { self.name = name; self.allocatedBytes = allocatedBytes }
}

/// One recipe and its state.
public struct RecipeStateRow: Codable, Equatable, Sendable {
    /// Its agent's id (`claude-code`).
    public var id: String
    /// `anthropic/claude-code` (with its source first when it is not Dozable's).
    public var qualified: String
    public var title: String
    /// What its agent is (`coding harness`), else "agent".
    public var subject: String
    /// Whose recipe: `Dozable`, `community · NAME`, `yours`.
    public var source: String
    /// `in use`, `installed` or `available`.
    public var state: String
    /// Carries this Mac's values but has no baked image (listed with the installed ones).
    public var notInstalled: Bool
    public var sandboxes: [String]
    public var images: [RecipeImage]
    public var imageBytes: Int64
    /// It is `defaults.image`'s agent (★).
    public var isDefault: Bool
    /// Its values set on this Mac (doz.toml), by option name.
    public var macValues: [String: TOMLValue]
    /// Where its settings live in doz.toml (`recipes.anthropic.claude-code`).
    public var section: String
    public var published: Bool

    public static let inUse = "in use", installed = "installed", available = "available"
}

public enum RecipeStates {
    /// Every recipe of the active set, with its state on this store and this Mac's settings, in the active set's order.
    public static func all(store: DozableStore, settings: DozableSettings = .load()) -> [RecipeStateRow] {
        var sandboxes: [String: [String]] = [:]
        for name in store.sandboxNames() {
            guard let cfg = SandboxConfig.read(store.configFile(name)), let id = agentID(cfg) else { continue }
            sandboxes[id, default: []].append(name)
        }
        var images: [String: [RecipeImage]] = [:]
        let baker = ImageBaker(storeRoot: store.root)
        for name in DozableImages.composedImagesInStore(store) {
            guard let c = ImageChoice.parse(name), let r = c.agent.recipe else { continue }
            let proto = ImageSpec(name: name, base: "", steps: [], verify: [], user: "", home: "", persistDirs: [])
            let bakes = baker.all(proto)
            guard !bakes.isEmpty else { continue }
            images[r.id, default: []].append(RecipeImage(name: name, allocatedBytes: bakes.reduce(0) { $0 + $1.manifest.allocatedBytes }))
        }
        let defaultImage = settings.string(SettingKey.defaultImage).flatMap { ImageChoice.parse($0)?.agent.recipe?.id }
        return AgentRecipes.all.map { r in
            var mac: [String: TOMLValue] = [:]
            for d in DozableSettings.recipeDefinitions(r.id) { if let v = settings.fileValues[d.key] { mac[d.name] = v } }
            let sb = sandboxes[r.id] ?? [], im = images[r.id] ?? []
            let state = !sb.isEmpty ? RecipeStateRow.inUse : (!im.isEmpty || !mac.isEmpty) ? RecipeStateRow.installed : RecipeStateRow.available
            return RecipeStateRow(id: r.id, qualified: r.qualifiedID, title: r.title, subject: r.subjectWords,
                                  source: r.origin.label ?? "Dozable", state: state, notInstalled: im.isEmpty && !mac.isEmpty,
                                  sandboxes: sb.sorted(), images: im, imageBytes: im.reduce(0) { $0 + $1.allocatedBytes },
                                  isDefault: r.id == defaultImage, macValues: mac, section: r.settingsSection, published: r.isPublished)
        }
    }

    /// The recipe whose agent a sandbox runs (a template follows the image it was saved from); nil: none (the lab, a base).
    public static func agentID(_ cfg: SandboxConfig) -> String? {
        (cfg.spec.imageSpec.flatMap { ImageChoice.parse($0.name) } ?? ImageChoice.parse(cfg.image))?.agent.recipe?.id
    }

    /// "Recipes in use: Claude Code, Codex · installed: pi" — `doz config show`'s line.
    public static func line(_ rows: [RecipeStateRow]) -> String {
        func names(_ s: String) -> String {
            let n = rows.filter { $0.state == s }.map { $0.title + ($0.notInstalled ? " (not installed)" : "") }
            return n.isEmpty ? "none" : n.joined(separator: ", ")
        }
        return "Recipes in use: \(names(RecipeStateRow.inUse)) · installed: \(names(RecipeStateRow.installed))"
    }
}
