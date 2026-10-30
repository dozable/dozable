import Foundation
import DozableKit
import DozableHost

// 669 (659 §0 Q1 "A, as a Recipes section"; items 12 and 16) — Settings › Recipes: every recipe of the active set with
// its state on this Mac (in use · installed · available — `RecipeStates`, read from the store alone, never starting a
// host) and its settings as the Settings page shows them (each with its source). The page lists the in-use and installed
// ones; the rest are reached by its search and Browse. A recipe's settings are changed through `POST /api/v1/settings`
// (one key, as every setting), its uninstall is the typed `resources-rm` of its baked images.

/// `GET /api/v1/recipes`.
public struct WebRecipes: Codable, Equatable, Sendable {
    public var recipes: [WebRecipe]
    /// The settings file's path (where "Mac" values live) and whether it parses.
    public var path: String?
    public var error: String?
}

/// One recipe, field by field.
public struct WebRecipe: Codable, Equatable, Sendable {
    public var id: String
    /// `anthropic/claude-code` — the page's address is `#/settings/recipes/<qualified>`.
    public var qualified: String
    public var title: String
    public var subject: String
    public var description: String?
    /// Whose recipe: `Dozable`, `community · NAME`, `yours`.
    public var source: String
    /// `in use` · `installed` · `available`.
    public var state: String
    public var notInstalled: Bool
    public var sandboxes: [String]
    public var images: [RecipeImage]
    public var imageBytes: Int64
    /// ★ — `defaults.image`'s agent.
    public var isDefault: Bool
    public var published: Bool
    /// doz.toml's `[recipes.V.P]`.
    public var section: String
    public var icon: ResolvedIcon?
    /// Its settings, with this Mac's value and source each (a value it sets shown as a chip in the list).
    public var settings: [SettingRow]
    /// Uninstall's resource ids (Resources' `image:NAME`), or why it is refused (a sandbox runs it).
    public var uninstallIDs: [String]
    public var uninstallRefusal: String?

    public static func list(store: DozableStore, settings: DozableSettings, flags: [String: TOMLValue] = [:]) -> WebRecipes {
        let report = settings.report(flags: flags)
        var byAgent: [String: [SettingRow]] = [:]
        for r in report.settings { if let a = r.agent { byAgent[a, default: []].append(r) } }
        let rows = RecipeStates.all(store: store, settings: settings).map { s -> WebRecipe in
            let r = AgentRecipes.recipe(s.id)
            let (refusal, ids) = RecipeStates.uninstallPlan(s)
            return WebRecipe(id: s.id, qualified: s.qualified, title: s.title, subject: s.subject, description: r?.description, source: s.source,
                             state: s.state, notInstalled: s.notInstalled, sandboxes: s.sandboxes, images: s.images, imageBytes: s.imageBytes,
                             isDefault: s.isDefault, published: s.published, section: s.section, icon: r.map(AgentIcons.resolve),
                             settings: byAgent[s.id] ?? [], uninstallIDs: ids, uninstallRefusal: refusal)
        }
        return WebRecipes(recipes: rows, path: report.path, error: report.error)
    }
}
